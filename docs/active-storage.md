# Active Storage operations

For reference, the shipped Active Storage operations declare:

| Operation | `deadline` | `memory` | `file_size` | `open_files` |
| --- | --- | --- | --- | --- |
| `transformers.image.vips`, `transformers.image.magick` | 30 | 1280MB | 48MB | 256 |
| `analyzers.image.vips`, `analyzers.image.magick` | 10 | 1024MB | 48MB | 64 |
| `analyzers.media.ffprobe` | 30 | 1024MB | 48MB | 128 |
| `previewers.pdf.mutool`, `previewers.pdf.poppler` | 30 | 1024MB | 48MB | 128 |
| `previewers.video.ffmpeg` | 120 | 1536MB | 128MB | 128 |

The 48MB is arithmetic from the example accessory — four workers, two staged files each, on a 512MB
tmpfs — and not a property of any operation. An operation that reads its input through the descriptor
stages only its output, so it needs half of what that arithmetic assumed.
