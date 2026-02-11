"""FastAPI application with WebSocket endpoint for real-time translation."""

import asyncio
import json
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware

from .config import get_settings
from .pipeline import PipelineOrchestrator
from .models import (
    TranscriptInterim,
    ClauseDetected,
    TranslationText,
    AudioOut,
)

# Configure logging
settings = get_settings()
logging.basicConfig(
    level=getattr(logging, settings.log_level),
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan handler."""
    logger.info("Starting Korean-English Translator Backend")
    yield
    logger.info("Shutting down Korean-English Translator Backend")


app = FastAPI(
    title="Korean-English Real-Time Translator",
    description="Real-time Korean to English speech translation using WebSockets",
    version="1.0.0",
    lifespan=lifespan,
)

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
async def health_check():
    """Health check endpoint to verify all API connections."""
    # Basic health check - could be extended to verify API connections
    return {
        "status": "healthy",
        "service": "korean-english-translator",
        "version": "1.0.0",
    }


@app.websocket("/ws/translate")
async def websocket_translate(websocket: WebSocket):
    """
    WebSocket endpoint for real-time translation.

    Protocol:
    - Client sends: binary audio chunks (PCM 16-bit, 16kHz, mono) or JSON control messages
    - Server sends: JSON status messages and binary audio chunks

    Control messages:
    - {"type": "control", "command": "start"} - Start translation session
    - {"type": "control", "command": "stop"} - Stop translation session
    - {"type": "control", "command": "flush"} - Flush buffers and translate remaining
    """
    await websocket.accept()
    logger.info(f"WebSocket connection accepted from {websocket.client}")

    pipeline: PipelineOrchestrator | None = None

    # Message send lock to prevent concurrent sends
    send_lock = asyncio.Lock()

    async def send_json(data: dict):
        """Send JSON message to client."""
        async with send_lock:
            try:
                await websocket.send_text(json.dumps(data))
            except Exception as e:
                logger.error(f"Error sending JSON: {e}")

    async def send_audio(data: bytes):
        """Send audio data to client."""
        async with send_lock:
            try:
                await websocket.send_bytes(data)
            except Exception as e:
                logger.error(f"Error sending audio: {e}")

    # Callbacks for pipeline events
    def on_interim(msg: TranscriptInterim):
        asyncio.create_task(send_json(msg.model_dump()))

    def on_clause(msg: ClauseDetected):
        asyncio.create_task(send_json(msg.model_dump()))

    def on_translation(msg: TranslationText):
        asyncio.create_task(send_json(msg.model_dump()))

    def on_audio(msg: AudioOut):
        asyncio.create_task(send_audio(msg.data))

    try:
        while True:
            # Receive message (can be binary audio or text control message)
            message = await websocket.receive()

            if "text" in message:
                # Parse control message
                try:
                    data = json.loads(message["text"])
                    msg_type = data.get("type")
                    command = data.get("command")

                    if msg_type == "control":
                        if command == "start":
                            # Start new pipeline
                            if pipeline and pipeline.is_running:
                                await pipeline.stop()

                            pipeline = PipelineOrchestrator(
                                on_interim=on_interim,
                                on_clause=on_clause,
                                on_translation=on_translation,
                                on_audio=on_audio,
                            )
                            await pipeline.start()
                            await send_json({
                                "type": "status",
                                "status": "started",
                                "session_id": pipeline.session_id,
                            })
                            logger.info(f"Translation session started: {pipeline.session_id}")

                        elif command == "stop":
                            if pipeline:
                                await pipeline.stop()
                                await send_json({
                                    "type": "status",
                                    "status": "stopped",
                                })
                                logger.info("Translation session stopped")
                                pipeline = None

                        elif command == "flush":
                            if pipeline:
                                await pipeline.flush()
                                await send_json({
                                    "type": "status",
                                    "status": "flushed",
                                })
                                logger.info("Buffers flushed")

                except json.JSONDecodeError:
                    logger.warning(f"Invalid JSON received: {message['text']}")

            elif "bytes" in message:
                # Audio data
                if pipeline and pipeline.is_running:
                    await pipeline.process_audio(message["bytes"])

    except WebSocketDisconnect:
        logger.info(f"WebSocket disconnected: {websocket.client}")
    except Exception as e:
        logger.error(f"WebSocket error: {e}")
    finally:
        # Clean up
        if pipeline:
            await pipeline.stop()
        logger.info("WebSocket connection closed")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
