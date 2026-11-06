#!/bin/sh
# Copies the shared, platform-independent HanX engine (document model,
# HWP/HWPX/DOCX/XLSX/PPTX readers and writers, formula engine) from a HanX
# checkout into Engine/. The iPad app compiles these files unchanged; the
# iOS-only pieces live in Engine/iOS and HanXPad/.
#   Scripts/sync-engine.sh ../HanX
set -eu
SRC="${1:?HanX 저장소 경로를 지정하세요 (예: Scripts/sync-engine.sh ../HanX)}/Sources"
DEST="$(cd "$(dirname "$0")/.." && pwd)/Engine"
[ -d "$SRC/Core" ] || { echo "HanX Sources 폴더를 찾을 수 없습니다: $SRC" >&2; exit 1; }
for f in Binary DocumentTemplates ImageAdjustments LegalNotices Model; do cp "$SRC/Core/$f.swift" "$DEST/Core/"; done
for f in CFB DOCXReader DOCXWriter DocumentIO HWP5Reader HWP5Writer HWPXReader HWPXWriter HanXFile TableGrid TextExport Zip; do
  cp "$SRC/Formats/$f.swift" "$DEST/Formats/"
done
cp "$SRC"/Sheet/*.swift "$DEST/Sheet/"
cp "$SRC"/Sheet/Functions/*.swift "$DEST/Sheet/Functions/"
cp "$SRC"/Slides/*.swift "$DEST/Slides/"
echo "엔진을 동기화했습니다: $DEST"
