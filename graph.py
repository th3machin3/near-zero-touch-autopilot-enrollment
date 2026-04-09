import os
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

    # Microsoft has accepted the import — return immediately.
    # Processing on Microsoft's end takes a few minutes and happens asynchronously.
    # The enrollment script handles the wait on the client side.
    imported = result.get("value", [])
    if not imported:
        raise Exception("No device returned from import request")

    return result
