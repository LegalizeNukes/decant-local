#!/bin/zsh
# decant-rawsvg-overlay — helper used by ./decant.
#
# Arguments:
#   1. path to Assets.car or .app
#   2. IconImageStack name
#   3. output .icon path
#
# The helper performs two extraction passes:
#   1. Normal extraction with icon-extract.m to preserve the layer/effect tree.
#   2. Minimal raw-SVG extraction to recover original rendition SVG bytes.
#
# Recovered raw SVGs are overlaid onto the normal extraction before build-icon.py
# assembles the final editable .icon bundle.

set -euo pipefail

if [[ $# -ne 3 ]]; then
  print -u2 "usage: zsh decant-rawsvg-overlay.zsh /path/to/Assets.car StackName /path/to/output.icon"
  exit 2
fi

INPUT="$1"
STACK="$2"
OUT_ICON="$3"

if [[ "$INPUT" == *.app ]]; then
  CAR="$INPUT/Contents/Resources/Assets.car"
else
  CAR="$INPUT"
fi

[[ -f "$CAR" ]] || { print -u2 "error: Assets.car not found: $CAR"; exit 1; }

ROOT_DIR="${0:A:h}"
EXTRACT_SRC="$ROOT_DIR/icon-extract.m"
BUILDER="$ROOT_DIR/build-icon.py"

[[ -f "$EXTRACT_SRC" ]] || { print -u2 "error: missing $EXTRACT_SRC"; exit 1; }
[[ -f "$BUILDER" ]] || { print -u2 "error: missing $BUILDER"; exit 1; }

TMPBASE="${TMPDIR:-/tmp}"
WORK=$(mktemp -d "$TMPBASE/decant-rawsvg.XXXXXX")
if [[ "${DECANT_KEEP_WORK:-0}" != 1 ]]; then
  trap 'rm -rf "$WORK"' EXIT
else
  print "work -> $WORK"
fi

FULL_RAW="$WORK/full-raw-extract"
RAWSVG="$WORK/rendition-rawsvg"
mkdir -p "$FULL_RAW" "$RAWSVG"
rm -rf "$OUT_ICON"

print "1/5 Compiling normal extractor..."
clang -fobjc-arc \
  -framework Foundation \
  -framework CoreGraphics \
  -framework ImageIO \
  -framework AppKit \
  "$EXTRACT_SRC" \
  -o "$WORK/icon-extract-normal.bin"

print "2/5 Running normal extraction..."
"$WORK/icon-extract-normal.bin" "$CAR" "$STACK" "$FULL_RAW"

cat > "$WORK/minimal-rawsvg-extract.m" <<'MEOF'
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

@interface CUICatalog : NSObject
- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
- (id)iconLayerStackWithName:(NSString *)name scaleFactor:(double)scale deviceIdiom:(long long)idiom deviceSubtype:(unsigned long long)subtype displayGamut:(long long)gamut appearanceName:(NSString *)appearance locale:(NSString *)locale;
@end

static id callObj(id obj, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    if (![obj respondsToSelector:sel]) return nil;

    NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments != 2 || sig.methodReturnType[0] != '@') return nil;

    @try {
        id (*msg)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        return msg(obj, sel);
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSString *safeFileName(NSString *s) {
    NSMutableString *m = [s mutableCopy];
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/:\\?%*|\"<> "];
    for (NSUInteger i = 0; i < m.length; i++) {
        if ([bad characterIsMember:[m characterAtIndex:i]]) {
            [m replaceCharactersInRange:NSMakeRange(i, 1) withString:@"_"];
        }
    }
    return m;
}

static BOOL looksLikeSVG(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length < 16) return NO;
    NSUInteger length = MIN((NSUInteger)4096, data.length);
    NSData *head = [data subdataWithRange:NSMakeRange(0, length)];
    NSString *text = [[NSString alloc] initWithData:head encoding:NSUTF8StringEncoding];
    if (!text) return NO;
    return [text rangeOfString:@"<svg" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [text rangeOfString:@"<?xml" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static void dumpLayer(id layer, NSString *outDir, NSMutableString *log, NSString *appearance) {
    NSString *className = NSStringFromClass([layer class]);
    NSString *name = callObj(layer, @"name") ?: className;

    BOOL candidate =
        [className localizedCaseInsensitiveContainsString:@"VectorSVG"] ||
        [name localizedCaseInsensitiveContainsString:@"svg"] ||
        [name localizedCaseInsensitiveContainsString:@"chiclet"] ||
        [name localizedCaseInsensitiveContainsString:@"bezier"];

    if (candidate) {
        id rendition = callObj(layer, @"_rendition");
        [log appendFormat:@"\nLAYER: %@\n  class: %@\n  appearance: %@\n  rendition: %@\n",
         name, className, appearance, rendition ? NSStringFromClass([rendition class]) : @"nil"];

        for (NSString *selectorName in @[@"rawData", @"data", @"srcData"]) {
            id value = callObj(rendition, selectorName);
            if ([value isKindOfClass:[NSData class]]) {
                NSData *data = (NSData *)value;
                BOOL isSVG = looksLikeSVG(data);
                [log appendFormat:@"  %@: %lu bytes looksLikeSVG=%@\n",
                 selectorName, (unsigned long)data.length, isSVG ? @"YES" : @"NO"];

                if (isSVG) {
                    NSString *fileName = [NSString stringWithFormat:@"%@__%@__%@.svg",
                                          safeFileName(name), appearance, selectorName];
                    NSString *path = [outDir stringByAppendingPathComponent:fileName];
                    [data writeToFile:path atomically:YES];
                    [log appendFormat:@"    wrote %@\n", fileName];
                    break;
                }
            } else {
                [log appendFormat:@"  %@: %@\n", selectorName, value ? NSStringFromClass([value class]) : @"nil"];
            }
        }
    }

    id children = callObj(layer, @"layers");
    if ([children isKindOfClass:[NSArray class]]) {
        for (id child in (NSArray *)children) dumpLayer(child, outDir, log, appearance);
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 4) return 2;

        dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW);

        NSString *carPath = @(argv[1]);
        NSString *stackName = @(argv[2]);
        NSString *outDir = @(argv[3]);

        NSError *error = nil;
        CUICatalog *catalog = [[NSClassFromString(@"CUICatalog") alloc]
                               initWithURL:[NSURL fileURLWithPath:carPath]
                               error:&error];
        if (!catalog) {
            fprintf(stderr, "catalog open failed: %s\n", error.description.UTF8String);
            return 1;
        }

        NSMutableString *log = [NSMutableString string];
        NSArray *appearances = @[@"NSAppearanceNameAqua", @"NSAppearanceNameDarkAqua", @"ISAppearanceTintable"];

        for (NSString *appearance in appearances) {
            id stack = [catalog iconLayerStackWithName:stackName
                                           scaleFactor:1
                                           deviceIdiom:0
                                         deviceSubtype:0
                                          displayGamut:0
                                        appearanceName:appearance
                                                locale:nil];
            [log appendFormat:@"\n===== %@ =====\n", appearance];
            if (stack) dumpLayer(stack, outDir, log, appearance);
            else [log appendString:@"STACK NOT FOUND\n"];
        }

        [log writeToFile:[outDir stringByAppendingPathComponent:@"rawsvg-log.txt"]
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:nil];
    }
    return 0;
}
MEOF

print "3/5 Compiling raw-SVG side extractor..."
clang -fobjc-arc -framework Foundation "$WORK/minimal-rawsvg-extract.m" -o "$WORK/minimal-rawsvg-extract.bin"

print "4/5 Overlaying original rendition SVGs when available..."
"$WORK/minimal-rawsvg-extract.bin" "$CAR" "$STACK" "$RAWSVG" >/dev/null

python3 - "$FULL_RAW" "$RAWSVG" <<'PY'
import re
import shutil
import sys
from pathlib import Path

full = Path(sys.argv[1])
raw = Path(sys.argv[2])
appearances = {"NSAppearanceNameAqua", "NSAppearanceNameDarkAqua", "ISAppearanceTintable"}

def norm_base(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9.]+", "", name)

def parse_full(path: Path):
    stem = path.stem
    for appearance in appearances:
        suffix = "__" + appearance
        if stem.endswith(suffix):
            return norm_base(stem[:-len(suffix)]), appearance
    return None

def parse_raw(path: Path):
    stem = path.stem
    for tail in ("__rawData", "__data", "__srcData"):
        if stem.endswith(tail):
            stem = stem[:-len(tail)]
            break
    for appearance in appearances:
        suffix = "__" + appearance
        if stem.endswith(suffix):
            return norm_base(stem[:-len(suffix)]), appearance
    return None

full_map = {}
for path in full.glob("*.svg"):
    key = parse_full(path)
    if key:
        full_map.setdefault(key, path)

replaced = []
for raw_svg in raw.glob("*.svg"):
    key = parse_raw(raw_svg)
    if not key:
        continue
    extracted_svg = full_map.get(key)
    if not extracted_svg:
        continue
    shutil.copy2(raw_svg, extracted_svg)
    replaced.append((raw_svg.name, extracted_svg.name, raw_svg.stat().st_size))

if replaced:
    print(f"Replaced {len(replaced)} SVG file(s) with original rendition SVGs:")
    for src, dst, size in replaced:
        print(f"  {src} -> {dst} ({size} bytes)")
else:
    print("No original rendition SVG replacements were available; using normal extraction.")
PY

print "5/5 Building .icon..."
python3 "$BUILDER" "$FULL_RAW" "$OUT_ICON"
