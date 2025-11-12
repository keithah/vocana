# Vocana

AI-powered noise cancellation and meeting transcription for Apple Silicon Mac. Local-only processing with Neural Engine optimization.

## Vision

Vocana combines the functionality of Krisp (AI noise cancellation) and Meeter (meeting management) into a single, privacy-focused macOS application that processes everything locally on Apple Silicon.

## Core Features

- **Real-time Noise Cancellation**: Using DeepFilterNet optimized for Apple Neural Engine
- **AI Meeting Transcription**: Local Whisper processing with Core ML
- **System-wide Virtual Audio Devices**: Core Audio HAL plugin creates "Vocana Microphone" and "Vocana Speaker" devices
- **Privacy-First**: All processing happens locally, no data leaves your Mac
- **Apple Silicon Optimized**: Designed specifically for M1+ Macs with Neural Engine acceleration

## MVP Scope

1. **Audio Processing**: Core Audio loopback driver + noise cancellation
2. **Transcription**: Real-time local Whisper processing
3. **Basic UI**: Menu bar interface with recording controls
4. **Local Storage**: SQLite database for transcript search and management

## Future Features

- Calendar integration (Apple Calendar, Google Calendar, Outlook)
- Meeting detection and metadata extraction
- AI summarization and action items
- Speaker diarization
- Dashboard interface
- Export to Apple Notes and Markdown

## Technical Stack

- **Language**: Swift + C (HAL plugin)
- **Platform**: macOS (Apple Silicon only)
- **Audio**: Core Audio HAL plugin, AudioServerPlugin framework
- **ML**: Core ML, Apple Neural Engine, ONNX Runtime
- **Storage**: SQLite
- **UI**: SwiftUI (menu bar) + AppKit (dashboard)

## Development Status

✅ **Core Audio HAL Plugin**: Complete system-wide virtual audio devices implementation
✅ **Noise Cancellation**: DeepFilterNet ML processing with real-time performance
✅ **Audio Pipeline**: End-to-end audio capture, processing, and output
✅ **Menu Bar Interface**: Device status and controls
✅ **Test Infrastructure**: Comprehensive unit and integration tests

🚧 **Transcription**: Real-time local Whisper processing (in progress)
🚧 **Dashboard UI**: Meeting management interface (planned)

## License

MIT License - see [LICENSE](LICENSE) file for details.
