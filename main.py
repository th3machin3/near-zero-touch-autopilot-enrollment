import logging
import os
import secrets
import string
import threading
import time
from collections import defaultdict
from datetime import datetime, timedelta

import requests as http_requests
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Header, Request
from fastapi.responses import PlainTextResponse
from fastapi.staticfiles import StaticFiles
from jinja2 import Environment, FileSystemLoader
from pydantic import BaseModel

from sqlalchemy import func
from database import SessionLocal, Code, SecurityEvent, FailedAttempt
from graph import import_autopilot_device

load_dotenv()

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("autopilot")

BACKEND_URL = os.getenv("BACKEND_URL", "https://enroll.yourcompany.com")
TOKEN_EXPIRY_DAYS = int(os.getenv("TOKEN_EXPIRY_DAYS", "7"))
SLACK_WEBHOOK_URL = os.getenv("SLACK_WEBHOOK_URL", "")

app = FastAPI()

jinja_env = Environment(loader=FileSystemLoader("templates"))

_slack_sent: dict[str, float] = {}  # "type:ip" -> last sent timestamp
SLACK_COOLDOWN = 300  # 5 minutes between alerts of same type per IP


def add_security_event(event_type: str, ip: str, detail: str):
    now = datetime.utcnow()
    event = {"time": now.isoformat(), "type": event_type, "ip": ip, "detail": detail}

    # Persist to database
    db = SessionLocal()
    try:
        db.add(SecurityEvent(time=now, type=event_type, ip=ip, detail=detail))
        db.commit()
    finally:
        db.close()

    if not SLACK_WEBHOOK_URL:
        return

    # Always alert on registrations and code generation, throttle everything else
    slack_key = f"{event_type}:{ip}"
    ts = time.time()
    if event_type in ("registration", "code_generated", "code_revoked", "unban"):
        threading.Thread(target=_send_slack_alert, args=(event,), daemon=True).start()
        _slack_sent[slack_key] = ts
    elif ts - _slack_sent.get(slack_key, 0) > SLACK_COOLDOWN:
        threading.Thread(target=_send_slack_alert, args=(event,), daemon=True).start()
        _slack_sent[slack_key] = ts


def _send_slack_alert(event: dict):
    emoji = {"failed_attempt": "🔴", "rate_limit": "🟡", "lockout": "🔒", "registration": "✅", "code_generated": "🆕", "code_revoked": "🗑️", "unban": "🔓"}.get(event["type"], "⚪")
    try:
        http_requests.post(SLACK_WEBHOOK_URL, json={
            "text": f"{emoji} *Autopilot Portal* — `{event['type']}`\nIP: `{event['ip']}`\n{event['detail']}"
        }, timeout=5)
    except Exception as e:
        logger.error(f"Slack webhook failed: {e}")

# Rate limiting per IP on public endpoints
_rate_limit: dict[str, list[float]] = defaultdict(list)
RATE_LIMIT_MAX = 10
RATE_LIMIT_WINDOW = 60  # seconds

# Failed attempt tracking — persisted in DB for durability across restarts
FAILED_MAX = int(os.getenv("LOCKOUT_MAX_ATTEMPTS", "5"))
FAILED_LOCKOUT = int(os.getenv("LOCKOUT_DURATION_HOURS", "24")) * 3600


def get_client_ip(request: Request) -> str:
    return request.headers.get("cf-connecting-ip") or request.client.host


def check_rate_limit(request: Request):
    ip = get_client_ip(request)
    now = time.time()
    cutoff = now - FAILED_LOCKOUT

    # Check lockout first (from DB)
    db = SessionLocal()
    try:
        count = db.query(FailedAttempt).filter(FailedAttempt.ip == ip, FailedAttempt.timestamp > cutoff).count()
        if count >= FAILED_MAX:
            logger.warning(f"Locked out IP {ip} — too many failed attempts")
            add_security_event("lockout", ip, f"IP locked out — {count} failed attempts in {FAILED_LOCKOUT}s")
            raise HTTPException(status_code=429, detail="Too many failed attempts. Try again later.")
    finally:
        db.close()

    # Rate limit (in-memory, short-lived)
    _rate_limit[ip] = [t for t in _rate_limit[ip] if now - t < RATE_LIMIT_WINDOW]
    if len(_rate_limit[ip]) >= RATE_LIMIT_MAX:
        logger.warning(f"Rate limited IP {ip}")
        add_security_event("rate_limit", ip, f"Rate limited — {RATE_LIMIT_MAX} requests in {RATE_LIMIT_WINDOW}s")
        raise HTTPException(status_code=429, detail="Too many requests")
    _rate_limit[ip].append(now)


def record_failed_attempt(request: Request):
    ip = get_client_ip(request)
    db = SessionLocal()
    try:
        db.add(FailedAttempt(ip=ip, timestamp=time.time()))
        db.commit()
        count = db.query(FailedAttempt).filter(FailedAttempt.ip == ip, FailedAttempt.timestamp > time.time() - FAILED_LOCKOUT).count()
    finally:
        db.close()
    logger.warning(f"Failed attempt from {ip} — total: {count}")
    add_security_event("failed_attempt", ip, "Invalid code submitted")


def generate_code() -> str:
    alphabet = string.ascii_uppercase + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(12))


## Admin endpoints are protected by Cloudflare Access SSO — no API key needed


def get_status(code: Code) -> str:
    if code.used:
        return "used"
    if code.expires_at < datetime.utcnow():
        return "expired"
    return "pending"


# --- API Routes ---


class GenerateRequest(BaseModel):
    label: str


@app.post("/api/codes/generate")
def generate(body: GenerateRequest, request: Request):
    db = SessionLocal()
    try:
        code_id = generate_code()
        while db.query(Code).filter(Code.id == code_id).first():
            code_id = generate_code()

        now = datetime.utcnow()
        code = Code(
            id=code_id,
            label=body.label,
            created_at=now,
            expires_at=now + timedelta(days=TOKEN_EXPIRY_DAYS),
        )
        db.add(code)
        db.commit()

        short_url = BACKEND_URL.replace("https://", "").replace("http://", "")
        oneliner = f"irm {short_url}/e/{code_id} | iex"
        add_security_event("code_generated", get_client_ip(request), f"New code generated for '{body.label}'")
        return {
            "code": code_id,
            "oneliner": oneliner,
            "expires_at": code.expires_at.isoformat(),
        }
    finally:
        db.close()


@app.get("/api/codes")
def list_codes():
    db = SessionLocal()
    try:
        codes = db.query(Code).order_by(Code.created_at.desc()).all()
        return [
            {
                "code": c.id,
                "label": c.label,
                "status": get_status(c),
                "serial": c.serial,
                "model": c.model,
                "created_at": c.created_at.isoformat(),
                "expires_at": c.expires_at.isoformat(),
                "used_at": c.used_at.isoformat() if c.used_at else None,
            }
            for c in codes
        ]
    finally:
        db.close()


@app.delete("/api/codes/{code}")
def delete_code(code: str, request: Request):
    db = SessionLocal()
    try:
        c = db.query(Code).filter(Code.id == code).first()
        if not c:
            raise HTTPException(status_code=404, detail="Code not found")
        label = c.label
        db.delete(c)
        db.commit()
        add_security_event("code_revoked", get_client_ip(request), f"Code revoked for '{label}'")
        return {"ok": True}
    finally:
        db.close()


@app.get("/e/{code}")
def enroll(code: str, request: Request):
    check_rate_limit(request)
    if len(code) != 12 or not code.isalnum():
        record_failed_attempt(request)
        raise HTTPException(status_code=404, detail="Code not found")
    db = SessionLocal()
    try:
        c = db.query(Code).filter(Code.id == code).first()
        if not c or c.used or c.expires_at < datetime.utcnow():
            record_failed_attempt(request)
            raise HTTPException(status_code=404, detail="Code not found")

        template = jinja_env.get_template("enroll.ps1.j2")
        rendered = template.render(
            code=c.id,
            label=c.label,
            expires_at=c.expires_at.isoformat(),
            backend_url=BACKEND_URL,
        )
        return PlainTextResponse(content=rendered, media_type="text/plain")
    finally:
        db.close()


class RegisterRequest(BaseModel):
    hardwareHash: str
    serial: str
    model: str | None = None


@app.post("/api/e")
def register(body: RegisterRequest, request: Request, authorization: str | None = Header(None)):
    check_rate_limit(request)
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing Bearer token")

    code_id = authorization.removeprefix("Bearer ").strip()
    if len(code_id) != 12 or not code_id.isalnum():
        record_failed_attempt(request)
        raise HTTPException(status_code=404, detail="Code not found")
    db = SessionLocal()
    try:
        c = db.query(Code).filter(Code.id == code_id).first()
        if not c or c.used or c.expires_at < datetime.utcnow():
            record_failed_attempt(request)
            raise HTTPException(status_code=404, detail="Code not found")

        try:
            result = import_autopilot_device(body.hardwareHash, body.serial)
        except Exception as e:
            logger.error(f"Autopilot import failed for {body.serial}: {e}")
            add_security_event("registration_failed", get_client_ip(request), f"Failed for serial {body.serial}: {e}")
            raise HTTPException(status_code=502, detail=f"Autopilot registration failed: {e}")

        c.used = True
        c.used_at = datetime.utcnow()
        c.serial = body.serial
        c.model = body.model or "Unknown"
        db.commit()

        logger.info(f"Device {body.serial} submitted to Autopilot — Microsoft will process asynchronously")
        add_security_event("registration", get_client_ip(request), f"Device submitted — serial: {body.serial}, model: {body.model or 'Unknown'}")
        return {"status": "ok", "serial": body.serial, "autopilot": "submitted"}
    finally:
        db.close()


@app.get("/api/bans")
def get_bans():
    now = time.time()
    cutoff = now - FAILED_LOCKOUT
    db = SessionLocal()
    try:
        rows = db.query(FailedAttempt.ip, func.count().label("cnt"), func.min(FailedAttempt.timestamp).label("earliest")).filter(
            FailedAttempt.timestamp > cutoff
        ).group_by(FailedAttempt.ip).all()
        bans = []
        for ip, cnt, earliest in rows:
            if cnt >= FAILED_MAX:
                remaining = int(FAILED_LOCKOUT - (now - earliest))
                bans.append({"ip": ip, "attempts": cnt, "remaining_seconds": max(remaining, 0)})
        return bans
    finally:
        db.close()


@app.delete("/api/bans/{ip}")
def unban_ip(ip: str, request: Request):
    db = SessionLocal()
    try:
        deleted = db.query(FailedAttempt).filter(FailedAttempt.ip == ip).delete()
        db.commit()
        if deleted:
            add_security_event("unban", get_client_ip(request), f"IP {ip} manually unbanned")
            return {"ok": True}
        raise HTTPException(status_code=404, detail="IP not found")
    finally:
        db.close()


@app.get("/api/events")
def get_events():
    db = SessionLocal()
    try:
        events = db.query(SecurityEvent).order_by(SecurityEvent.id.desc()).limit(100).all()
        return [
            {"time": e.time.isoformat(), "type": e.type, "ip": e.ip, "detail": e.detail}
            for e in events
        ]
    finally:
        db.close()


@app.delete("/api/events")
def clear_events():
    db = SessionLocal()
    try:
        db.query(SecurityEvent).delete()
        db.commit()
        return {"ok": True}
    finally:
        db.close()


# Admin UI served at /admin — protect this path with Cloudflare Access
app.mount("/admin", StaticFiles(directory="static", html=True), name="static")
