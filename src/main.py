"""FastAPI application with WebSocket endpoint for bidirectional translation."""

import asyncio
import json
import logging
import uuid
from contextlib import asynccontextmanager
from typing import Optional, Dict

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware

from .config import get_settings
from .models import (
    TranslationDirection,
    SessionStart,
    AudioChunk,
    ConfigUpdate,
    TranscriptInterim,
    TranscriptFinal,
    ClassifierDecision,
    TranslationResult,
    AudioOut,
    ErrorMessage,
    GenderDetected,
)
from .session import Session, SessionManager, SharedTranslationContext
from .services import STTService, TTSService, TranslatorService, GenderDetector
from .pipelines import KrToEnPipeline, EnToKrPipeline

# Configure logging
settings = get_settings()
logging.basicConfig(
    level=getattr(logging, settings.log_level),
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)


# =============================================================================
# ROOM MANAGEMENT FOR BIDIRECTIONAL TRANSLATION
# =============================================================================

class ConversationRoom:
    """Manages a bidirectional translation session between two participants."""

    def __init__(self, room_id: str):
        self.room_id = room_id
        self.participants: Dict[str, WebSocket] = {}  # "en" or "ko" -> websocket
        self.orchestrators: Dict[str, "BidirectionalOrchestrator"] = {}  # "en" or "ko" -> orchestrator
        self.shared_context = SharedTranslationContext()
        logger.info(f"[Room {room_id}] Created")

    def add_participant(self, language: str, websocket: WebSocket, orchestrator: "BidirectionalOrchestrator"):
        """Add a participant to the room."""
        self.participants[language] = websocket
        self.orchestrators[language] = orchestrator
        logger.info(f"[Room {self.room_id}] Added {language} participant")

    def get_partner_socket(self, my_language: str) -> Optional[WebSocket]:
        """Get the WebSocket of the partner (opposite language)."""
        partner_lang = "ko" if my_language == "en" else "en"
        return self.participants.get(partner_lang)

    def remove_participant(self, language: str, websocket: Optional[WebSocket] = None) -> bool:
        """
        Remove a participant from the room.

        With websocket, only removes the entry if it still belongs to that socket,
        so a stale connection closing late (e.g. the user re-joined on a new socket
        after Stop) can't evict the newer one. Returns True if removed.
        """
        if websocket is not None and self.participants.get(language) is not websocket:
            return False
        if language in self.participants:
            del self.participants[language]
        if language in self.orchestrators:
            del self.orchestrators[language]
        logger.info(f"[Room {self.room_id}] Removed {language} participant")
        return True

    def is_empty(self) -> bool:
        """Check if the room has no participants."""
        return len(self.participants) == 0

    def has_both_participants(self) -> bool:
        """Check if both participants are connected."""
        return "en" in self.participants and "ko" in self.participants

    async def notify_partner(self, my_language: str, message: dict):
        """Send a message to the partner."""
        partner_socket = self.get_partner_socket(my_language)
        if partner_socket:
            try:
                await partner_socket.send_text(json.dumps(message))
            except Exception as e:
                logger.error(f"[Room {self.room_id}] Error notifying partner: {e}")

    async def route_translation_output(self, direction: str, audio_data: bytes):
        """
        Route translated audio to the appropriate listener.

        direction tells us the pipeline that produced this audio:
        - "ko_to_en" output goes to the English speaker (they hear English translation of Korean)
        - "en_to_ko" output goes to the Korean speaker (they hear Korean translation of English)
        """
        # Determine who should receive this audio
        target_lang = "en" if direction == "ko_to_en" else "ko"
        target_socket = self.participants.get(target_lang)

        if target_socket:
            try:
                import base64
                await target_socket.send_text(json.dumps({
                    "type": "audio",
                    "direction": direction,
                    "format": "mp3",
                    "data": base64.b64encode(audio_data).decode()
                }))
                logger.debug(f"[Room {self.room_id}] Routed {len(audio_data)} bytes to {target_lang}")
            except Exception as e:
                logger.error(f"[Room {self.room_id}] Error routing audio: {e}")


# Room storage
rooms: Dict[str, ConversationRoom] = {}


# =============================================================================
# WIFI AUTO-PAIRING MANAGER
# =============================================================================

class WiFiPairingManager:
    """Handles automatic pairing of users on the same WiFi network."""

    def __init__(self):
        # wifi_id -> {"en": (websocket, user_id, event), "ko": (websocket, user_id, event)}
        self.queue: Dict[str, Dict[str, tuple]] = {}
        self.lock = asyncio.Lock()

    async def try_pair(
        self,
        wifi_identifier: str,
        user_language: str,
        websocket: WebSocket,
        user_id: str
    ) -> Optional[tuple]:
        """
        Try to pair this user with someone on the same WiFi.

        KEY RULE: Only pairs OPPOSITE languages (en with ko, ko with en).
        Two users with the same language will NOT be paired.

        Returns:
            - None if no match found (user added to queue)
            - (room_id, partner_ws, partner_id) if matched with opposite language user
        """
        async with self.lock:
            if wifi_identifier not in self.queue:
                self.queue[wifi_identifier] = {}

            wifi_queue = self.queue[wifi_identifier]
            opposite_language = "ko" if user_language == "en" else "en"

            # Check if there's a user with the OPPOSITE language waiting
            if opposite_language in wifi_queue:
                # Found a match! Create room
                partner_ws, partner_id, partner_event = wifi_queue[opposite_language]

                # Remove partner from queue
                del wifi_queue[opposite_language]

                # Clean up empty wifi queue
                if not wifi_queue:
                    del self.queue[wifi_identifier]

                # Generate room ID
                room_id = f"auto_{uuid.uuid4().hex[:8]}"

                # Signal the partner that we found a match
                partner_event.set()

                logger.info(f"[WiFi Pairing] Matched {user_language} with {opposite_language} on {wifi_identifier[:20]}... -> Room {room_id}")
                return room_id, partner_ws, partner_id

            else:
                # No opposite-language partner found
                # Check if same language user already waiting (edge case)
                if user_language in wifi_queue:
                    # Another user with SAME language is waiting - don't replace
                    logger.info(f"[WiFi Pairing] Same-language user already waiting on {wifi_identifier[:20]}...")
                    return None

                # Add to queue and wait
                match_event = asyncio.Event()
                wifi_queue[user_language] = (websocket, user_id, match_event)
                logger.info(f"[WiFi Pairing] {user_language} user waiting on {wifi_identifier[:20]}...")
                return None

    async def wait_for_match(
        self,
        wifi_identifier: str,
        user_language: str,
        timeout: float = 30.0
    ) -> bool:
        """Wait for a match to be found. Returns True if matched, False if timeout."""
        async with self.lock:
            if wifi_identifier not in self.queue:
                return False
            if user_language not in self.queue[wifi_identifier]:
                return False
            _, _, event = self.queue[wifi_identifier][user_language]

        try:
            await asyncio.wait_for(event.wait(), timeout=timeout)
            return True
        except asyncio.TimeoutError:
            return False

    async def remove_from_queue(self, wifi_identifier: str, user_language: str):
        """Remove a user from the waiting queue (timeout or disconnect)."""
        async with self.lock:
            if wifi_identifier in self.queue:
                if user_language in self.queue[wifi_identifier]:
                    del self.queue[wifi_identifier][user_language]
                    logger.info(f"[WiFi Pairing] Removed {user_language} from {wifi_identifier[:20]}...")
                if not self.queue[wifi_identifier]:
                    del self.queue[wifi_identifier]


wifi_pairing_manager = WiFiPairingManager()


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan handler."""
    logger.info("Starting Bidirectional Korean-English Translator Backend")
    yield
    logger.info("Shutting down Bidirectional Korean-English Translator Backend")


app = FastAPI(
    title="Bidirectional Korean-English Translator",
    description="Real-time bidirectional Korean to English speech translation",
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

# Session manager
session_manager = SessionManager()


@app.get("/health")
async def health_check():
    """Health check endpoint."""
    return {
        "status": "healthy",
        "service": "bidirectional-translator",
        "version": "1.0.0",
        "active_sessions": session_manager.session_count,
    }


class BidirectionalOrchestrator:
    """Coordinates both pipelines within a session."""

    def __init__(
        self,
        session: Session,
        websocket: WebSocket,
        room: Optional[ConversationRoom] = None,
        user_language: Optional[str] = None,
    ):
        """
        Initialize the orchestrator.

        Args:
            session: The translation session.
            websocket: The WebSocket connection.
            room: Optional ConversationRoom for bidirectional pairing.
            user_language: User's language ("en" or "ko") for routing in room.
        """
        self.session = session
        self.ws = websocket
        self.room = room
        self.user_language = user_language
        self._send_lock = asyncio.Lock()

        # Shared services
        self.translator = TranslatorService()
        self.tts = TTSService()

        # Gender detection (one per direction to handle multi-speaker scenarios)
        self.gender_detectors: dict[TranslationDirection, GenderDetector] = {
            TranslationDirection.KO_TO_EN: GenderDetector(),
            TranslationDirection.EN_TO_KO: GenderDetector(),
        }

        # Initialize pipelines based on session config
        self.kr_to_en: Optional[KrToEnPipeline] = None
        self.en_to_kr: Optional[EnToKrPipeline] = None

        if session.has_direction(TranslationDirection.KO_TO_EN):
            ko_stt = STTService(language="ko")
            self.kr_to_en = KrToEnPipeline(
                context=session.shared_context,
                stt=ko_stt,
                translator=self.translator,
                tts=self.tts,
                on_interim=lambda msg: self._schedule_send(msg),
                on_final=lambda msg: self._schedule_send(msg),
                on_classifier=lambda msg: self._schedule_send(msg),
                on_translation=lambda msg: self._schedule_send(msg),
                on_audio=lambda msg: self._schedule_send_audio(msg),
            )

        if session.has_direction(TranslationDirection.EN_TO_KO):
            en_stt = STTService(language="en")
            self.en_to_kr = EnToKrPipeline(
                context=session.shared_context,
                stt=en_stt,
                translator=self.translator,
                tts=self.tts,
                honorific_mode=session.honorific_mode,
                on_interim=lambda msg: self._schedule_send(msg),
                on_final=lambda msg: self._schedule_send(msg),
                on_translation=lambda msg: self._schedule_send(msg),
                on_audio=lambda msg: self._schedule_send_audio(msg),
            )

    async def start(self) -> None:
        """Start all active pipelines."""
        await self.tts.start()

        if self.kr_to_en:
            await self.kr_to_en.start()
        if self.en_to_kr:
            await self.en_to_kr.start()

        logger.info(f"Orchestrator started for session {self.session.id}")

    async def stop(self) -> None:
        """Stop all pipelines and clean up."""
        if self.kr_to_en:
            await self.kr_to_en.stop()
        if self.en_to_kr:
            await self.en_to_kr.stop()

        await self.tts.stop()
        logger.info(f"Orchestrator stopped for session {self.session.id}")

    async def handle_audio(
        self,
        direction: TranslationDirection,
        data: bytes,
        timestamp_ms: int,
        gender_override: Optional[str] = None,
    ) -> None:
        """Route audio to appropriate pipeline and detect gender."""
        # Handle gender override from frontend
        if gender_override:
            self.session.gender_override = gender_override
            self.tts.set_gender(gender_override)

        # Perform gender detection on audio (if not already detected and no override)
        if not self.session.gender_override:
            detector = self.gender_detectors.get(direction)
            if detector and not detector.is_complete:
                detected = detector.add_audio(data)
                if detected:
                    # Store detected gender in session
                    self.session.detected_gender = detected
                    # Update TTS with detected gender
                    self.tts.set_gender(self.session.effective_gender)
                    # Notify frontend
                    self._schedule_send(GenderDetected(
                        gender=detected,
                        direction=direction,
                    ))

        # Route audio to appropriate pipeline
        if direction == TranslationDirection.KO_TO_EN and self.kr_to_en:
            await self.kr_to_en.process_audio(data, timestamp_ms)
        elif direction == TranslationDirection.EN_TO_KO and self.en_to_kr:
            await self.en_to_kr.process_audio(data, timestamp_ms)
        else:
            logger.warning(f"No pipeline for direction: {direction}")

    async def update_config(
        self,
        honorific_mode: Optional[bool] = None,
        gender_override: Optional[str] = None,
    ) -> None:
        """Update session configuration."""
        if honorific_mode is not None:
            self.session.honorific_mode = honorific_mode
            if self.en_to_kr:
                self.en_to_kr.set_honorific(honorific_mode)
            logger.info(f"Updated honorific mode to: {honorific_mode}")

        if gender_override is not None:
            self.session.gender_override = gender_override
            self.tts.set_gender(gender_override)
            logger.info(f"Updated gender override to: {gender_override}")

    def _schedule_send(self, msg) -> None:
        """Schedule a JSON message to be sent."""
        asyncio.create_task(self._send_json(msg.model_dump()))

    def _schedule_send_audio(self, msg: AudioOut) -> None:
        """Schedule audio data to be sent."""
        asyncio.create_task(self._send_audio(msg))

    async def _send_json(self, data: dict) -> None:
        """Send JSON message to client."""
        async with self._send_lock:
            try:
                await self.ws.send_text(json.dumps(data))
            except Exception as e:
                logger.error(f"Error sending JSON: {e}")

    async def _send_audio(self, msg: AudioOut) -> None:
        """Send audio data with direction prefix, routing to partner if in a room."""
        import base64

        # If in a room WITH a partner, route audio to that partner.
        # Solo speaker (no partner socket yet) falls through to the self-send
        # branch below so she hears her own translation.
        partner_lang = "en" if msg.direction.value == "ko_to_en" else "ko"
        if self.room and self.room.participants.get(partner_lang) is not None:
            # The direction tells us which pipeline produced this audio:
            # - ko_to_en output goes to the English speaker
            # - en_to_ko output goes to the Korean speaker
            await self.room.route_translation_output(
                msg.direction.value,
                msg.data
            )
            return

        # Legacy mode: send to current websocket
        async with self._send_lock:
            try:
                # Send as JSON with base64 encoded audio for consistency
                await self.ws.send_text(json.dumps({
                    "type": "audio",
                    "direction": msg.direction.value,
                    "format": msg.format,
                    "data": base64.b64encode(msg.data).decode()
                }))
            except Exception as e:
                logger.error(f"Error sending audio: {e}")


@app.websocket("/ws/translate")
async def websocket_translate(websocket: WebSocket):
    """
    WebSocket endpoint for bidirectional translation with room support.

    Protocol:
    - Client sends start_session with:
      - pairing_mode: "wifi_auto" or "manual"
      - user_language: "en" or "ko" (what THIS user speaks)
      - room_id: (optional) for joining existing room
      - wifi_identifier: (optional) for auto-pairing
      - config: {honorific_mode: bool}
    - Client sends audio_chunk with direction tag
    - Client can send config_update to change settings
    - Client sends session_end to stop
    """
    await websocket.accept()
    logger.info(f"WebSocket connection accepted from {websocket.client}")

    orchestrator: Optional[BidirectionalOrchestrator] = None
    session: Optional[Session] = None
    room: Optional[ConversationRoom] = None
    user_language: Optional[str] = None
    wifi_identifier: Optional[str] = None
    user_id = str(uuid.uuid4())

    async def send_json(data: dict):
        try:
            await websocket.send_text(json.dumps(data))
        except Exception as e:
            logger.error(f"Error sending JSON: {e}")

    async def send_error(message: str, direction: Optional[TranslationDirection] = None):
        msg = ErrorMessage(direction=direction, message=message)
        await send_json(msg.model_dump())

    async def setup_orchestrator_for_room(
        room: ConversationRoom,
        user_lang: str,
        honorific_mode: bool
    ) -> tuple:
        """Set up session and orchestrator for a room participant."""
        # Determine directions based on user language
        # Both directions are active in a room for bidirectional translation
        directions = [TranslationDirection.KO_TO_EN, TranslationDirection.EN_TO_KO]

        session = session_manager.create_session(
            directions=directions,
            honorific_mode=honorific_mode,
        )

        # Create orchestrator with room context for audio routing
        orch = BidirectionalOrchestrator(
            session=session,
            websocket=websocket,
            room=room,
            user_language=user_lang,
        )
        await orch.start()

        # A previous socket's cleanup may have deleted this room as empty while we were
        # starting (quick re-join after Stop) - re-register it so a partner can still find it
        if room.room_id not in rooms:
            rooms[room.room_id] = room

        # Add to room
        room.add_participant(user_lang, websocket, orch)

        return session, orch

    try:
        while True:
            message = await websocket.receive()

            if message.get("type") == "websocket.disconnect":
                # Client closed the socket; calling receive() again would raise RuntimeError
                raise WebSocketDisconnect(message.get("code", 1000))

            if "text" in message:
                try:
                    data = json.loads(message["text"])
                    msg_type = data.get("type")

                    # Log received messages for debugging (audio chunks are logged
                    # at DEBUG below, without their base64 payload)
                    if msg_type != "audio_chunk":
                        logger.info(f"Received message: {data}")

                    # Handle both "session_start" and "start_session"
                    if msg_type in ("session_start", "start_session"):
                        logger.info(f"Processing session start: {data}")

                        # Clean up existing session (before user_language is replaced)
                        if orchestrator:
                            await orchestrator.stop()
                        if session:
                            session_manager.end_session(session.id)
                        if room and user_language:
                            room.remove_participant(user_language, websocket)
                            if room.is_empty() and rooms.get(room.room_id) is room:
                                del rooms[room.room_id]

                        # Parse user language (new room-based protocol)
                        user_language = data.get("user_language")
                        pairing_mode = data.get("pairing_mode", "manual")
                        room_id = data.get("room_id")
                        wifi_identifier = data.get("wifi_identifier")
                        config = data.get("config", {})
                        honorific_mode = config.get("honorific_mode", data.get("honorific_mode", False))

                        # ========== WIFI AUTO-PAIRING MODE ==========
                        if pairing_mode == "wifi_auto" and wifi_identifier and user_language:
                            logger.info(f"WiFi auto-pairing: {user_language} user on {wifi_identifier[:20]}...")

                            # Try to find a partner with OPPOSITE language on same WiFi
                            result = await wifi_pairing_manager.try_pair(
                                wifi_identifier=wifi_identifier,
                                user_language=user_language,
                                websocket=websocket,
                                user_id=user_id
                            )

                            if result is None:
                                # No partner found yet, notify client we're waiting
                                await send_json({
                                    "type": "pairing_status",
                                    "status": "waiting",
                                    "message": "Looking for a partner on the same network..."
                                })

                                # Wait for pairing (with timeout)
                                matched = await wifi_pairing_manager.wait_for_match(
                                    wifi_identifier=wifi_identifier,
                                    user_language=user_language,
                                    timeout=30.0
                                )

                                if not matched:
                                    # Timeout - tell client to use manual pairing
                                    await wifi_pairing_manager.remove_from_queue(wifi_identifier, user_language)
                                    await send_json({
                                        "type": "pairing_status",
                                        "status": "timeout",
                                        "message": "No partner found. Please use manual pairing."
                                    })
                                    continue

                                # If we get here, we were matched by another user connecting
                                # The matching user created the room and notified us
                                # Continue to receive the session_started from them

                            else:
                                # Successfully paired! Create the room
                                matched_room_id, partner_ws, partner_id = result

                                # Create the room
                                room = ConversationRoom(matched_room_id)
                                rooms[matched_room_id] = room

                                # Set up this user's orchestrator
                                session, orchestrator = await setup_orchestrator_for_room(
                                    room, user_language, honorific_mode
                                )

                                # Notify both users of successful pairing
                                response = {
                                    "type": "session_started",
                                    "room_id": matched_room_id,
                                    "paired_via": "wifi_auto"
                                }
                                await send_json(response)
                                try:
                                    await partner_ws.send_text(json.dumps(response))
                                except:
                                    pass

                                # Send partner_joined to both
                                await send_json({"type": "partner_joined"})
                                try:
                                    await partner_ws.send_text(json.dumps({"type": "partner_joined"}))
                                except:
                                    pass

                        # ========== MANUAL PAIRING MODE ==========
                        elif user_language:
                            if not room_id:
                                # Create new room
                                room_id = uuid.uuid4().hex[:6].upper()  # e.g., "ABC123"
                                room = ConversationRoom(room_id)
                                rooms[room_id] = room
                                logger.info(f"Created room {room_id} for {user_language} user")

                            elif room_id not in rooms:
                                # Room doesn't exist - create it (first joiner)
                                room = ConversationRoom(room_id)
                                rooms[room_id] = room
                                logger.info(f"Created room {room_id} for joining {user_language} user")

                            else:
                                # Join existing room
                                room = rooms[room_id]
                                logger.info(f"User {user_language} joining existing room {room_id}")

                            # Set up orchestrator
                            session, orchestrator = await setup_orchestrator_for_room(
                                room, user_language, honorific_mode
                            )

                            # Notify session started
                            await send_json({
                                "type": "session_started",
                                "room_id": room_id,
                                "paired_via": "manual"
                            })

                            # Notify partner if they're already in the room
                            partner_socket = room.get_partner_socket(user_language)
                            if partner_socket:
                                try:
                                    await partner_socket.send_text(json.dumps({"type": "partner_joined"}))
                                    await send_json({"type": "partner_joined"})
                                except:
                                    pass

                        # ========== LEGACY MODE (backward compatibility) ==========
                        else:
                            # Fall back to old direction-based protocol
                            directions_raw = data.get("directions", [])
                            if not directions_raw:
                                single_direction = data.get("direction")
                                if single_direction:
                                    directions_raw = [single_direction]

                            directions = []
                            for d in directions_raw:
                                try:
                                    directions.append(TranslationDirection(d))
                                except ValueError:
                                    logger.error(f"Invalid direction value: {d}")

                            if not directions:
                                await send_error("No translation directions specified")
                                continue

                            # Create session without room
                            session = session_manager.create_session(
                                directions=directions,
                                honorific_mode=honorific_mode,
                            )

                            orchestrator = BidirectionalOrchestrator(
                                session=session,
                                websocket=websocket,
                            )
                            await orchestrator.start()

                            response = {
                                "type": "session_started",
                                "status": "session_started",
                                "session_id": session.id,
                                "room_id": session.id,  # Use session ID as room ID for legacy
                                "direction": directions[0].value if directions else None,
                                "directions": [d.value for d in directions],
                                "honorific_mode": honorific_mode,
                            }
                            await send_json(response)

                    elif msg_type == "config_update":
                        if not orchestrator:
                            await send_error("No active session")
                            continue

                        await orchestrator.update_config(
                            honorific_mode=data.get("honorific_mode"),
                            gender_override=data.get("gender_override"),
                        )
                        await send_json({
                            "type": "status",
                            "status": "config_updated",
                            "honorific_mode": session.honorific_mode if session else None,
                            "gender": session.effective_gender if session else None,
                        })

                    elif msg_type == "audio_chunk":
                        if not orchestrator:
                            logger.warning("audio_chunk received but no active session")
                            await send_error("No active session")
                            continue

                        direction_str = data.get("direction")
                        try:
                            direction = TranslationDirection(direction_str)
                        except ValueError:
                            logger.error(f"Invalid direction in audio_chunk: {direction_str}")
                            await send_error(f"Invalid direction: {direction_str}")
                            continue

                        # Audio data should be base64 encoded in JSON
                        import base64
                        audio_data = base64.b64decode(data.get("data", ""))
                        timestamp_ms = data.get("timestamp_ms", data.get("timestamp", 0))
                        gender_override = data.get("gender_override")

                        logger.debug(f"Received audio_chunk: direction={direction_str}, size={len(audio_data)} bytes")

                        await orchestrator.handle_audio(
                            direction, audio_data, timestamp_ms, gender_override
                        )

                    elif msg_type == "session_end":
                        if orchestrator:
                            await orchestrator.stop()
                            orchestrator = None
                        if session:
                            session_manager.end_session(session.id)
                            session = None

                        await send_json({
                            "type": "status",
                            "status": "session_ended",
                        })

                    else:
                        logger.warning(f"Unknown message type: {msg_type}")

                except json.JSONDecodeError:
                    logger.warning(f"Invalid JSON: {message['text'][:100]}")
                except Exception as e:
                    logger.error(f"Error processing message: {e}")
                    import traceback
                    traceback.print_exc()
                    await send_error(str(e))

            elif "bytes" in message:
                # Binary audio - handle raw binary if direction is known
                if orchestrator and session:
                    if session.active_directions:
                        await orchestrator.handle_audio(
                            session.active_directions[0],
                            message["bytes"],
                            0,
                        )

    except WebSocketDisconnect:
        logger.info(f"WebSocket disconnected: {websocket.client}")
    except Exception as e:
        logger.error(f"WebSocket error: {e}")
        import traceback
        traceback.print_exc()
    finally:
        # Clean up
        if orchestrator:
            await orchestrator.stop()
        if session:
            session_manager.end_session(session.id)

        # Notify partner and clean up room
        if room and user_language:
            # Remove from room, unless the user already re-joined on a newer socket
            # (e.g. mic tap right after Stop while this handler was still in stop())
            if room.remove_participant(user_language, websocket):
                # Notify partner
                partner_socket = room.get_partner_socket(user_language)
                if partner_socket:
                    try:
                        await partner_socket.send_text(json.dumps({"type": "partner_left"}))
                    except:
                        pass

            # Clean up empty rooms
            if room.is_empty() and rooms.get(room.room_id) is room:
                del rooms[room.room_id]
                logger.info(f"Deleted empty room {room.room_id}")

        # Clean up from WiFi pairing queue if still waiting
        if wifi_identifier and user_language:
            await wifi_pairing_manager.remove_from_queue(wifi_identifier, user_language)

        logger.info("WebSocket connection closed")


# =============================================================================
# PAIRING ENDPOINT
# =============================================================================

# Store waiting clients for pairing (by IP network)
pairing_clients: dict[str, dict] = {}  # ip_prefix -> {client_id: {websocket, direction, headphones, ip}}
pairing_rooms: dict[str, dict] = {}    # room_code -> {clients: [...], room_id: str}

def get_ip_prefix(ip: str) -> str:
    """Extract network prefix from IP for WiFi matching (first 3 octets)."""
    parts = ip.split(".")
    if len(parts) >= 3:
        return ".".join(parts[:3])
    return ip

def generate_room_code() -> str:
    """Generate a 6-digit room code."""
    import random
    return "".join([str(random.randint(0, 9)) for _ in range(6)])

def generate_room_id() -> str:
    """Generate a unique room ID."""
    import uuid
    return str(uuid.uuid4())[:8].upper()

@app.websocket("/ws/pair")
async def websocket_pair(websocket: WebSocket, direction: str = "ko_to_en"):
    """
    WebSocket endpoint for pairing two clients.

    Protocol:
    - Client connects with ?direction=ko_to_en or ?direction=en_to_ko
    - Client sends {"type": "headphone_status", "connected": true/false}
    - Server sends status updates:
      - {"type": "searching"} - looking for partner
      - {"type": "partner_connected", "headphones": bool} - partner found
      - {"type": "partner_ready"} - partner has headphones
      - {"type": "matched", "room_id": "..."} - both ready, can start
      - {"type": "no_match", "room_code": "..."} - timeout, use manual pairing
    """
    await websocket.accept()

    # Get client IP
    client_ip = websocket.client.host if websocket.client else "unknown"
    ip_prefix = get_ip_prefix(client_ip)
    client_id = f"{client_ip}:{id(websocket)}"

    logger.info(f"Pairing connection from {client_ip} (prefix: {ip_prefix}), direction: {direction}")

    # Initialize client data
    client_data = {
        "websocket": websocket,
        "direction": direction,
        "headphones": False,
        "ip": client_ip,
        "ip_prefix": ip_prefix,
    }

    # Add to waiting clients
    if ip_prefix not in pairing_clients:
        pairing_clients[ip_prefix] = {}
    pairing_clients[ip_prefix][client_id] = client_data

    partner_ws: Optional[WebSocket] = None
    partner_id: Optional[str] = None
    room_code: Optional[str] = None
    matched = False

    async def send_json(data: dict):
        try:
            await websocket.send_text(json.dumps(data))
        except Exception as e:
            logger.error(f"Error sending pairing message: {e}")

    async def send_to_partner(data: dict):
        if partner_ws:
            try:
                await partner_ws.send_text(json.dumps(data))
            except Exception as e:
                logger.error(f"Error sending to partner: {e}")

    async def check_for_partner():
        """Look for a partner on the same WiFi network with opposite direction."""
        nonlocal partner_ws, partner_id

        opposite_direction = "en_to_ko" if direction == "ko_to_en" else "ko_to_en"

        # Look in same IP prefix
        if ip_prefix in pairing_clients:
            for cid, cdata in pairing_clients[ip_prefix].items():
                if cid != client_id and cdata["direction"] == opposite_direction:
                    partner_id = cid
                    partner_ws = cdata["websocket"]
                    return True
        return False

    async def check_match():
        """Check if both clients have headphones and are ready."""
        nonlocal matched

        if partner_id and ip_prefix in pairing_clients:
            partner_data = pairing_clients[ip_prefix].get(partner_id)
            if partner_data and client_data["headphones"] and partner_data["headphones"]:
                # Both have headphones - create room and notify
                room_id = generate_room_id()
                matched = True

                await send_json({"type": "matched", "room_id": room_id})
                await send_to_partner({"type": "matched", "room_id": room_id})

                logger.info(f"Pairing matched! Room: {room_id}, clients: {client_id}, {partner_id}")
                return True
        return False

    try:
        # Send initial searching status
        await send_json({"type": "searching"})

        # Check for existing partner
        if await check_for_partner():
            partner_data = pairing_clients[ip_prefix].get(partner_id)
            await send_json({
                "type": "partner_connected",
                "headphones": partner_data["headphones"] if partner_data else False
            })
            # Notify partner about us
            await send_to_partner({
                "type": "partner_connected",
                "headphones": client_data["headphones"]
            })

        # Set up timeout for WiFi matching (6 seconds)
        match_timeout = asyncio.create_task(asyncio.sleep(6))

        while not matched:
            try:
                # Wait for message with timeout check
                receive_task = asyncio.create_task(websocket.receive_text())

                done, pending = await asyncio.wait(
                    [receive_task, match_timeout],
                    return_when=asyncio.FIRST_COMPLETED
                )

                if match_timeout in done and not matched:
                    # Timeout - go to manual pairing
                    room_code = generate_room_code()
                    await send_json({"type": "no_match", "room_code": room_code})
                    logger.info(f"Pairing timeout for {client_id}, room_code: {room_code}")

                    # Store room code for manual joining
                    pairing_rooms[room_code] = {
                        "clients": [client_data],
                        "room_id": generate_room_id()
                    }

                    # Cancel receive task and continue listening for manual join
                    receive_task.cancel()
                    continue

                if receive_task in done:
                    message = receive_task.result()
                    data = json.loads(message)
                    msg_type = data.get("type")

                    if msg_type == "headphone_status":
                        client_data["headphones"] = data.get("connected", False)
                        logger.info(f"Client {client_id} headphones: {client_data['headphones']}")

                        # Notify partner
                        if partner_ws:
                            if client_data["headphones"]:
                                await send_to_partner({"type": "partner_ready"})
                            else:
                                await send_to_partner({
                                    "type": "partner_connected",
                                    "headphones": False
                                })

                        # Check for partner if we don't have one
                        if not partner_ws:
                            if await check_for_partner():
                                partner_data = pairing_clients[ip_prefix].get(partner_id)
                                await send_json({
                                    "type": "partner_connected",
                                    "headphones": partner_data["headphones"] if partner_data else False
                                })
                                await send_to_partner({
                                    "type": "partner_connected",
                                    "headphones": client_data["headphones"]
                                })

                        # Check if we can match
                        await check_match()

                    elif msg_type == "join_room":
                        # Manual room joining
                        join_code = data.get("room_code")
                        if join_code in pairing_rooms:
                            room_data = pairing_rooms[join_code]
                            room_data["clients"].append(client_data)

                            # Notify both clients
                            room_id = room_data["room_id"]
                            for c in room_data["clients"]:
                                try:
                                    await c["websocket"].send_text(json.dumps({
                                        "type": "matched",
                                        "room_id": room_id
                                    }))
                                except:
                                    pass

                            matched = True
                            logger.info(f"Manual pairing joined! Room: {room_id}")

            except asyncio.CancelledError:
                break
            except json.JSONDecodeError:
                logger.warning("Invalid JSON in pairing message")
            except Exception as e:
                logger.error(f"Error in pairing loop: {e}")
                break

    except WebSocketDisconnect:
        logger.info(f"Pairing client disconnected: {client_id}")
    except Exception as e:
        logger.error(f"Pairing WebSocket error: {e}")
    finally:
        # Clean up
        if ip_prefix in pairing_clients and client_id in pairing_clients[ip_prefix]:
            del pairing_clients[ip_prefix][client_id]
            if not pairing_clients[ip_prefix]:
                del pairing_clients[ip_prefix]

        # Notify partner of disconnect
        if partner_ws and not matched:
            try:
                await partner_ws.send_text(json.dumps({"type": "partner_disconnected"}))
            except:
                pass

        logger.info(f"Pairing connection closed: {client_id}")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=settings.host, port=settings.port)
