from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="Project SHAKED Sovereign Ledger Backend")


class SovereignTransferRequest(BaseModel):
    asset: str
    action: str
    amount: int
    destination_wallet: str


@app.get("/reserve_status")
def reserve_status() -> dict:
    return {
        "asset": "Digital Shekel (ILS-D)",
        "total_supply": 50000000.00,
        "status": "active",
    }


@app.post("/sovereign_transfer")
def sovereign_transfer(payload: SovereignTransferRequest) -> dict:
    return {
        "status": "settled",
        "transaction_id": "TXN-9982",
        "amount_transferred": payload.amount,
    }
