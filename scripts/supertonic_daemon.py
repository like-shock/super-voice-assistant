#!/usr/bin/env python3
"""
Supertonic TTS Daemon
=====================
Swift 앱에서 stdin/stdout 바이너리 프로토콜로 통신하는 상주 프로세스.

프로토콜:
  Request:  [4 bytes: text_length (little-endian uint32)][text_length bytes: UTF-8 text]
  Response: [4 bytes: pcm_length (little-endian uint32)][pcm_length bytes: 16-bit PCM @ 44100Hz mono]

특수 명령:
  "PING"     → "PONG\n" (텍스트 응답, health check)
  "QUIT"     → 프로세스 종료
  "VOICE:X"  → 음성 스타일 변경 (예: "VOICE:F1")
  "LANG:X"   → 언어 변경 (예: "LANG:en")
  "SPEED:X"  → 속도 변경 (예: "SPEED:1.2")

시작 시 stderr로 "READY\n" 출력 (모델 로딩 완료 신호).
"""

import sys
import struct
import time
import numpy as np

def main():
    voice_name = sys.argv[1] if len(sys.argv) > 1 else "M1"
    lang = sys.argv[2] if len(sys.argv) > 2 else "ko"
    speed = float(sys.argv[3]) if len(sys.argv) > 3 else 1.05
    total_steps = int(sys.argv[4]) if len(sys.argv) > 4 else 5

    # 모델 로딩 (1회)
    sys.stderr.write(f"LOADING model... voice={voice_name} lang={lang} speed={speed}\n")
    sys.stderr.flush()

    from supertonic import TTS

    tts = TTS(auto_download=True)
    style = tts.get_voice_style(voice_name=voice_name)
    sample_rate = tts.sample_rate  # 44100

    sys.stderr.write(f"READY sample_rate={sample_rate}\n")
    sys.stderr.flush()

    while True:
        try:
            # 요청 헤더 읽기 (4 bytes)
            header = sys.stdin.buffer.read(4)
            if not header or len(header) < 4:
                break

            text_len = struct.unpack('<I', header)[0]
            if text_len == 0:
                continue
            if text_len > 100_000:  # 안전 제한: 100KB
                sys.stderr.write(f"ERROR: text too long ({text_len} bytes)\n")
                sys.stderr.flush()
                # 빈 응답
                sys.stdout.buffer.write(struct.pack('<I', 0))
                sys.stdout.buffer.flush()
                continue

            text = sys.stdin.buffer.read(text_len).decode('utf-8')

            # 특수 명령 처리
            if text == "PING":
                sys.stdout.buffer.write(b"PONG\n")
                sys.stdout.buffer.flush()
                continue
            elif text == "QUIT":
                sys.stderr.write("QUIT received, exiting.\n")
                sys.stderr.flush()
                break
            elif text.startswith("VOICE:"):
                new_voice = text[6:].strip()
                try:
                    style = tts.get_voice_style(voice_name=new_voice)
                    voice_name = new_voice
                    sys.stderr.write(f"VOICE changed to {new_voice}\n")
                except Exception as e:
                    sys.stderr.write(f"ERROR changing voice: {e}\n")
                sys.stderr.flush()
                # 빈 응답으로 ACK
                sys.stdout.buffer.write(struct.pack('<I', 0))
                sys.stdout.buffer.flush()
                continue
            elif text.startswith("LANG:"):
                lang = text[5:].strip()
                sys.stderr.write(f"LANG changed to {lang}\n")
                sys.stderr.flush()
                sys.stdout.buffer.write(struct.pack('<I', 0))
                sys.stdout.buffer.flush()
                continue
            elif text.startswith("SPEED:"):
                try:
                    speed = float(text[6:].strip())
                    sys.stderr.write(f"SPEED changed to {speed}\n")
                except ValueError:
                    sys.stderr.write(f"ERROR: invalid speed value\n")
                sys.stderr.flush()
                sys.stdout.buffer.write(struct.pack('<I', 0))
                sys.stdout.buffer.flush()
                continue

            # TTS 합성
            t0 = time.time()
            wav, duration = tts.synthesize(
                text,
                voice_style=style,
                lang=lang,
                total_steps=total_steps,
                speed=speed
            )
            elapsed = time.time() - t0

            # float32 → 16-bit PCM
            samples = wav.flatten()
            pcm16 = (samples * 32767).astype(np.int16)
            pcm_bytes = pcm16.tobytes()

            sys.stderr.write(
                f"SYNTH len={len(text)} audio={duration[0]:.2f}s "
                f"pcm={len(pcm_bytes)} elapsed={elapsed:.3f}s\n"
            )
            sys.stderr.flush()

            # 응답: [pcm_length][pcm_data]
            sys.stdout.buffer.write(struct.pack('<I', len(pcm_bytes)))
            sys.stdout.buffer.write(pcm_bytes)
            sys.stdout.buffer.flush()

        except KeyboardInterrupt:
            break
        except Exception as e:
            sys.stderr.write(f"ERROR: {e}\n")
            sys.stderr.flush()
            # 에러 시 빈 응답
            try:
                sys.stdout.buffer.write(struct.pack('<I', 0))
                sys.stdout.buffer.flush()
            except:
                break

    sys.stderr.write("Daemon stopped.\n")
    sys.stderr.flush()


if __name__ == "__main__":
    main()
