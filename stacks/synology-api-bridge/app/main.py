"""Internal-only DSM HTTP helper — allowlisted APIs only; strict timeouts; no generic DSM proxy."""

from __future__ import annotations

import os
from typing import Annotated

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

app = FastAPI(title="synology-api-bridge", version="0.2.0")

DSM_BASE_URL = os.environ.get("DSM_BASE_URL", "").rstrip("/")
HTTP_TIMEOUT = float(os.environ.get("DSM_HTTP_TIMEOUT_SECONDS", "5.0"))
EXPECTED_SECRET = os.environ.get("BRIDGE_SHARED_SECRET", "")

# Fixed Synology Web API tuples (api, method, version) — no user-controlled api/method/version.
_SYNO_API_INFO = ("SYNO.API.Info", "query", "1")


def _check_secret(x_bridge_secret: str | None) -> None:
    if not EXPECTED_SECRET:
        raise HTTPException(status_code=503, detail="BRIDGE_SHARED_SECRET not configured")
    if not x_bridge_secret or x_bridge_secret != EXPECTED_SECRET:
        raise HTTPException(status_code=401, detail="invalid or missing X-Bridge-Secret")


BridgeAuth = Annotated[str | None, Header(alias="X-Bridge-Secret")]


def require_bridge_secret(x: BridgeAuth) -> None:
    _check_secret(x)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/v1/dsm/ping", dependencies=[Depends(require_bridge_secret)])
async def v1_dsm_ping() -> dict[str, str]:
    if not DSM_BASE_URL:
        return {"dsm": "skipped", "reason": "DSM_BASE_URL unset"}
    url = f"{DSM_BASE_URL}/"
    try:
        async with httpx.AsyncClient(timeout=HTTP_TIMEOUT) as client:
            r = await client.get(url)
        return {"dsm": "ok", "status_code": str(r.status_code)}
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"dsm unreachable: {exc!s}") from exc


@app.get("/v1/syno-api/info", dependencies=[Depends(require_bridge_secret)])
async def v1_syno_api_info() -> dict[str, object]:
    """Allowlisted: SYNO.API.Info version=1 method=query only."""
    if not DSM_BASE_URL:
        raise HTTPException(status_code=400, detail="DSM_BASE_URL unset")
    api, method, version = _SYNO_API_INFO
    params = {"api": api, "version": version, "method": method}
    url = f"{DSM_BASE_URL}/webapi/entry.cgi"
    try:
        async with httpx.AsyncClient(timeout=HTTP_TIMEOUT) as client:
            r = await client.get(url, params=params)
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"syno api info failed: {exc!s}") from exc
    body = r.text
    return {
        "api": api,
        "method": method,
        "version": version,
        "status_code": r.status_code,
        "body_length": len(body),
    }


class FileStationListRequest(BaseModel):
    folder_path: str = Field("/", max_length=2048, description="Reserved for future allowlisted File Station list")


@app.post("/v1/file-station/list", dependencies=[Depends(require_bridge_secret)])
async def v1_file_station_list(_body: FileStationListRequest) -> dict[str, str]:
    raise HTTPException(
        status_code=501,
        detail="SYNO.FileStation not implemented in v1 — extend with session auth and allowlisted methods only.",
    )
