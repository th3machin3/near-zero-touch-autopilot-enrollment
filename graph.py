import os
import time
import logging
import msal
import requests

logger = logging.getLogger("autopilot")


def get_graph_token():
    authority = f"https://login.microsoftonline.com/{os.getenv('ENTRA_TENANT_ID')}"
    app = msal.ConfidentialClientApplication(
        os.getenv("ENTRA_CLIENT_ID"),
        authority=authority,
        client_credential=os.getenv("ENTRA_CLIENT_SECRET"),
    )
    result = app.acquire_token_for_client(scopes=["https://graph.microsoft.com/.default"])
    if "access_token" not in result:
        error = result.get('error_description', result)
        logger.error(f"MSAL token acquisition failed: {error}")
        raise Exception(f"Failed to acquire token: {error}")
    return result["access_token"]


def import_autopilot_device(hardware_hash: str, serial: str):
    token = get_graph_token()
    group_tag = os.getenv("AUTOPILOT_GROUP_TAG", "")
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }

    # Submit the import
    url = "https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities/import"
    device_identity = {
        "hardwareIdentifier": hardware_hash,
        "serialNumber": serial,
    }
    if group_tag:
        device_identity["groupTag"] = group_tag
    payload = {
        "importedWindowsAutopilotDeviceIdentities": [device_identity]
    }
    resp = requests.post(url, json=payload, headers=headers)
    if not resp.ok:
        detail = resp.text[:500]
        logger.error(f"Graph API import failed ({resp.status_code}): {detail}")
        # Extract a clean error message if possible
        try:
            err = resp.json().get("error", {})
            msg = err.get("message", detail)
        except Exception:
            msg = detail
        raise Exception(f"Graph API {resp.status_code}: {msg[:200]}")
    result = resp.json()

    # Extract the import ID to poll status
    imported = result.get("value", [])
    if not imported:
        raise Exception("No device returned from import request")

    device_id = imported[0].get("id")
    if not device_id:
        logger.warning("No device ID returned — skipping status polling")
        return result

    # Poll for import completion (max 5 minutes)
    status_url = f"https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities/{device_id}"
    max_wait = 300  # 5 minutes
    poll_interval = 10  # seconds
    elapsed = 0

    while elapsed < max_wait:
        time.sleep(poll_interval)
        elapsed += poll_interval

        status_resp = requests.get(status_url, headers=headers)
        if status_resp.status_code != 200:
            logger.warning(f"Status poll returned {status_resp.status_code}, continuing...")
            continue

        status_data = status_resp.json()
        state = status_data.get("state", {})
        device_import_status = state.get("deviceImportStatus", "unknown")
        device_error_code = state.get("deviceErrorCode", 0)

        logger.info(f"Import status for {serial}: {device_import_status} (elapsed: {elapsed}s)")

        if device_import_status == "complete":
            return status_data
        elif device_import_status == "error":
            error_name = state.get("deviceErrorName", "Unknown error")
            raise Exception(f"Autopilot import failed: {error_name} (code: {device_error_code})")

    raise Exception(f"Autopilot import timed out after {max_wait}s — device may still be processing")
