import os
from sqlalchemy import create_engine, Column, Text, DateTime, Boolean, Integer, Float
from sqlalchemy.orm import sessionmaker, declarative_base

os.makedirs("data", exist_ok=True)

DATABASE_URL = "sqlite:///data/enrollment.db"

engine = create_engine(DATABASE_URL, connect_args={"check_same_thread": False})
SessionLocal = sessionmaker(bind=engine)
Base = declarative_base()


class Code(Base):
    __tablename__ = "codes"

    id = Column(Text, primary_key=True)
    label = Column(Text)
    created_at = Column(DateTime)
    expires_at = Column(DateTime)
    used = Column(Boolean, default=False)
    used_at = Column(DateTime, nullable=True)
    serial = Column(Text, nullable=True)
    model = Column(Text, nullable=True)


class SecurityEvent(Base):
    __tablename__ = "security_events"

    id = Column(Integer, primary_key=True, autoincrement=True)
    time = Column(DateTime)
    type = Column(Text)
    ip = Column(Text)
    detail = Column(Text)


class FailedAttempt(Base):
    __tablename__ = "failed_attempts"

    id = Column(Integer, primary_key=True, autoincrement=True)
    ip = Column(Text, index=True)
    timestamp = Column(Float)


Base.metadata.create_all(bind=engine)
