from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="Mock Sovereign API", version="0.2.0")


class TransactionRequest(BaseModel):
    ticker: str
    action: str
    qty: int
    price: float


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
