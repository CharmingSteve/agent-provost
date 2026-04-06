from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="Mock Sovereign API", version="0.2.0")


class SovereignTransferRequest(BaseModel):
    asset: str
    action: str
    amount: int
    destination_wallet: str


class TransactionRequest(BaseModel):
    ticker: str
    action: str
    qty: int
    price: float


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


@app.get("/portfolio")
def get_portfolio() -> dict:
    return {
        "cash": 100000.00,
        "buying_power": 200000.00,
        "open_positions": ["AAPL", "MSFT"],
    }


@app.post("/transaction")
def post_transaction(req: TransactionRequest) -> dict:
    return {
        "status": "filled",
        "notional_value": req.qty * req.price,
    }
