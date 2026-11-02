"""Local development entry point: uv run uvicorn app.main:app."""

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import PlainTextResponse

from app.observability import close_logging, configure_logging, record
from app.tone import create_backend
from app.ws import router


@asynccontextmanager
async def lifespan(app: FastAPI):
    handlers = configure_logging(verbose=app.state.verbose)
    version = app.state.tone_backend.model_version
    record(logging.INFO, "server_started", version, log_file=handlers[1].baseFilename)
    try:
        yield
    finally:
        record(logging.INFO, "server_stopped", version)
        close_logging(handlers)


async def health() -> str:
    return "ok"


def create_app(*, verbose: bool = False) -> FastAPI:
    app = FastAPI(title="Graption tone server", lifespan=lifespan)
    app.state.verbose = verbose
    # TONE_BACKEND picks the model (default mock); see app/tone.py.
    app.state.tone_backend = create_backend()
    app.include_router(router)
    app.add_api_route("/health", health, response_class=PlainTextResponse)
    return app


app = create_app()
