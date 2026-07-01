#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

typedef struct CGSVGDocument *CGSVGDocumentRef;
static void (*CGSVGDocumentWriteToURL_)(CGSVGDocumentRef, CFURLRef, CFDictionaryRef);

@interface CUICatalog : NSObject
- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
- (id)_namedLookupWithName:(NSString *)name scaleFactor:(double)scale deviceIdiom:(long long)idiom deviceSubtype:(unsigned long long)subtype displayGamut:(long long)gamut layoutDirection:(long long)dir sizeClassHorizontal:(long long)h sizeClassVertical:(long long)v appearanceName:(NSString *)appearance locale:(NSString *)locale;
- (id)iconLayerStackWithName:(NSString *)name scaleFactor:(double)scale deviceIdiom:(long long)idiom deviceSubtype:(unsigned long long)subtype displayGamut:(long long)gamut appearanceName:(NSString *)appearance locale:(NSString *)locale;
- (CGColorRef)colorWithName:(NSString *)name displayGamut:(long long)gamut deviceIdiom:(long long)idiom appearanceName:(NSString *)appearance;
- (id)_appearancefallback_gradientWithName:(NSString *)name displayGamut:(long long)gamut deviceIdiom:(long long)idiom appearanceName:(NSString *)appearance;
- (NSArray *)allImageNames;
- (void)enumerateNamedLookupsUsingBlock:(void (^)(id))block;
@end

static NSString *safeName(NSString *n) {
    return [[n stringByReplacingOccurrencesOfString:@"/" withString:@"__"] stringByReplacingOccurrencesOfString:@" " withString:@"_"];
}

static void savePNG(CGImageRef img, NSString *path) {
    if (!img) return;
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    if (!dest) return;
    CGImageDestinationAddImage(dest, img, NULL);
    CGImageDestinationFinalize(dest);
    CFRelease(dest);
}


static id callObjDirect(id obj, NSString *selName) {
    SEL s = NSSelectorFromString(selName);
    if (![obj respondsToSelector:s]) return nil;
    NSMethodSignature *sig = [obj methodSignatureForSelector:s];
    if (!sig) return nil;
    if (sig.numberOfArguments != 2) return nil;
    if (sig.methodReturnType[0] != '@') return nil;
    @try {
        id (*msg)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        return msg(obj, s);
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static BOOL dataLooksLikeSVG(NSData *d) {
    if (![d isKindOfClass:[NSData class]] || d.length < 16) return NO;
    NSUInteger n = MIN((NSUInteger)4096, d.length);
    NSString *s = [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(0, n)] encoding:NSUTF8StringEncoding];
    if (!s) return NO;
    return [s rangeOfString:@"<svg" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [s rangeOfString:@"<?xml" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSData *rawSVGDataForLayer(id layer, NSString **sourceOut) {
    id rendition = callObjDirect(layer, @"_rendition");
    if (!rendition) return nil;

    for (NSString *selName in @[@"rawData", @"data", @"srcData"]) {
        id v = callObjDirect(rendition, selName);
        if ([v isKindOfClass:[NSData class]] && dataLooksLikeSVG((NSData *)v)) {
            if (sourceOut) *sourceOut = [NSString stringWithFormat:@"%@.%@", NSStringFromClass([rendition class]), selName];
            return (NSData *)v;
        }
    }
    return nil;
}

static id colorJSON(CGColorRef c) {
    if (!c) return [NSNull null];
    CGColorSpaceRef cs = CGColorGetColorSpace(c);
    CFStringRef csName = cs ? CGColorSpaceCopyName(cs) : NULL;
    size_t n = CGColorGetNumberOfComponents(c);
    const CGFloat *comp = CGColorGetComponents(c);
    NSMutableArray *arr = [NSMutableArray array];
    for (size_t i=0;i<n;i++) [arr addObject:@(comp[i])];
    return @{ @"colorspace": csName ? (__bridge_transfer NSString*)csName : @"?", @"components": arr };
}

static id val(id obj, NSString *selName) {
    SEL s = NSSelectorFromString(selName);
    if (![obj respondsToSelector:s]) return nil;
    NSMethodSignature *sig = [obj methodSignatureForSelector:s];
    const char *rt = sig.methodReturnType;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = obj; inv.selector = s;
    [inv invoke];
    if (rt[0]=='@') { __unsafe_unretained id r; [inv getReturnValue:&r]; return r; }
    if (rt[0]=='d') { double d; [inv getReturnValue:&d]; return @(d); }
    if (rt[0]=='i') { int i; [inv getReturnValue:&i]; return @(i); }
    if (rt[0]=='q') { long long q; [inv getReturnValue:&q]; return @(q); }
    if (rt[0]=='Q') { unsigned long long q; [inv getReturnValue:&q]; return @(q); }
    if (rt[0]=='B') { BOOL b; [inv getReturnValue:&b]; return @(b); }
    return nil;
}

static NSDictionary *dumpLayer(id layer, NSString *outDir, NSString *appearance) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSString *layerClassName = NSStringFromClass([layer class]);
    d[@"class"] = layerClassName;

    // Critical ordering: fetch only the layer name, then immediately try
    // _rendition.rawData before touching svgDocument/image/frame/effect
    // properties. Some CoreUI/CoreSVG accessors materialize a lossy
    // regenerated SVG and make the original rawData path unavailable.
    NSString *lname = callObjDirect(layer, @"name") ?: @"unnamed";
    d[@"name"] = lname;

    BOOL isVectorSVGLayerEarly =
        [layer isKindOfClass:NSClassFromString(@"CUINamedVectorSVGImage")] ||
        [layerClassName localizedCaseInsensitiveContainsString:@"VectorSVG"] ||
        [lname localizedCaseInsensitiveContainsString:@"chiclet"] ||
        [lname localizedCaseInsensitiveContainsString:@"bezier"];

    NSData *prefetchedRawSVG = nil;
    NSString *prefetchedRawSource = nil;
    if (isVectorSVGLayerEarly) {
        prefetchedRawSVG = rawSVGDataForLayer(layer, &prefetchedRawSource);
        if (prefetchedRawSVG) {
            d[@"rawSVGPrefetchedBeforeProperties"] = @YES;
            d[@"rawSVGPrefetchSource"] = prefetchedRawSource ?: @"_rendition.rawData";
            d[@"rawSVGPrefetchBytes"] = @((unsigned long)prefetchedRawSVG.length);
        } else {
            d[@"rawSVGPrefetchedBeforeProperties"] = @NO;
        }
    }

    for (NSString *p in @[@"opacity", @"blendMode", @"blurStrength", @"hasLightingEffects", @"gradientOrColorName", @"fixedFrame", @"gathersSpecularByElement", @"hasSpecular", @"translucency", @"shadowStyle", @"shadowOpacity", @"renditionName", @"appearance",
                          // iOS 26+/27 Liquid Glass fields (absent in older CoreUI):
                          @"refractionStrength", @"refractionHeight", @"specularPlacement", @"sourceObjectVersion"]) {
        id v = val(layer, p);
        if (v) d[p] = v;
    }
    if ([layer respondsToSelector:@selector(frame)]) {
        CGRect f = ((CGRect (*)(id, SEL))objc_msgSend)(layer, @selector(frame));
        d[@"frame"] = [NSString stringWithFormat:@"{{%g, %g}, {%g, %g}}", f.origin.x, f.origin.y, f.size.width, f.size.height];
    }
    // color fill
    if ([layer respondsToSelector:NSSelectorFromString(@"color")]) {
        CGColorRef c = ((CGColorRef (*)(id, SEL))objc_msgSend)(layer, NSSelectorFromString(@"color"));
        if (c) d[@"color"] = colorJSON(c);
    }
    id grad = val(layer, @"gradient");
    if (grad) {
        NSMutableArray *cols = [NSMutableArray array];
        for (id c in (NSArray *)val(grad, @"colors")) cols[cols.count] = colorJSON((__bridge CGColorRef)c);
        CGPoint sp = ((CGPoint (*)(id, SEL))objc_msgSend)(grad, NSSelectorFromString(@"gradientStartPoint"));
        CGPoint ep = ((CGPoint (*)(id, SEL))objc_msgSend)(grad, NSSelectorFromString(@"gradientEndPoint"));
        d[@"gradient"] = @{ @"name": val(grad, @"name") ?: @"?", @"type": val(grad, @"gradientType") ?: @(-1),
                            @"start": [NSString stringWithFormat:@"{%g, %g}", sp.x, sp.y], @"end": [NSString stringWithFormat:@"{%g, %g}", ep.x, ep.y],
                            @"stops": (NSArray *)val(grad, @"colorStops") ?: @[], @"colors": cols };
    }
    // image payload
    if ([layer respondsToSelector:NSSelectorFromString(@"image")] && ![layer isKindOfClass:NSClassFromString(@"CUINamedVectorSVGImage")]) {
        CGImageRef img = ((CGImageRef (*)(id, SEL))objc_msgSend)(layer, NSSelectorFromString(@"image"));
        if (img) {
            NSString *fn = [NSString stringWithFormat:@"%@__%@.png", safeName(lname), appearance];
            savePNG(img, [outDir stringByAppendingPathComponent:fn]);
            d[@"savedImage"] = fn;
            d[@"imageSize"] = [NSString stringWithFormat:@"%zux%zu", CGImageGetWidth(img), CGImageGetHeight(img)];
        }
    }
    BOOL isVectorSVGLayer = isVectorSVGLayerEarly;

    if (isVectorSVGLayer) {
        NSString *fn = [NSString stringWithFormat:@"%@__%@.svg", safeName(lname), appearance];
        NSString *path = [outDir stringByAppendingPathComponent:fn];

        // Prefer the original SVG XML preserved in the CoreUI rendition.
        // CGSVGDocumentWriteToURL can regenerate an incomplete SVG for some
        // Assets.car vector layers, dropping clipPath definitions while keeping
        // clip-path references. Pixelmator's 3.chiclet.line and 5.bezier.dots
        // are examples. This mirrors the minimal diagnostic extractor that
        // successfully recovered _CUIThemeSVGRendition.rawData.
        NSString *rawSource = prefetchedRawSource;
        NSData *raw = prefetchedRawSVG;
        if (raw) {
            [raw writeToFile:path atomically:YES];
            d[@"savedSVG"] = fn;
            d[@"svgSource"] = rawSource ?: @"_rendition.rawData";
            d[@"svgBytes"] = @((unsigned long)raw.length);
        } else {
            SEL svgSel = NSSelectorFromString(@"svgDocument");
            if ([layer respondsToSelector:svgSel] && CGSVGDocumentWriteToURL_) {
                CGSVGDocumentRef doc = ((CGSVGDocumentRef (*)(id, SEL))objc_msgSend)(layer, svgSel);
                if (doc) {
                    CGSVGDocumentWriteToURL_(doc, (__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
                    d[@"savedSVG"] = fn;
                    d[@"svgSource"] = @"CGSVGDocumentWriteToURL";
                } else {
                    d[@"svgSource"] = @"none-svgDocument-nil";
                }
            } else {
                d[@"svgSource"] = @"none-no-svgDocument-selector";
            }
        }
    }
    // recurse into sub-layers (groups)
    NSArray *sub = val(layer, @"layers");
    if (sub) {
        NSMutableArray *subDumps = [NSMutableArray array];
        for (id sl in sub) [subDumps addObject:dumpLayer(sl, outDir, appearance)];
        d[@"layers"] = subDumps;
    }
    return d;
}

// Resolve a named gradient/color lookup for a given appearance and return its
// colors/stops/orientation. The enumerated lookup must be refreshed via
// _updateFromCatalog: before its colors populate.
static NSDictionary *resolveGradient(id lk, CUICatalog *cat, NSString *appearance) {
    SEL up = NSSelectorFromString(@"_updateFromCatalog:displayGamut:deviceIdiom:appearanceName:");
    if ([lk respondsToSelector:up])
        ((void (*)(id, SEL, id, long long, long long, id))objc_msgSend)(lk, up, cat, 0LL, 0LL, appearance);
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSArray *cols = val(lk, @"colors");
    if (cols) {
        NSMutableArray *cj = [NSMutableArray array];
        for (id c in cols) [cj addObject:colorJSON((__bridge CGColorRef)c)];
        d[@"colors"] = cj;
    }
    id stops = val(lk, @"colorStops");
    if (stops) d[@"stops"] = stops;
    id type = val(lk, @"gradientType");
    if (type) d[@"type"] = type;
    if ([lk respondsToSelector:NSSelectorFromString(@"gradientStartPoint")]) {
        CGPoint sp = ((CGPoint (*)(id, SEL))objc_msgSend)(lk, NSSelectorFromString(@"gradientStartPoint"));
        CGPoint ep = ((CGPoint (*)(id, SEL))objc_msgSend)(lk, NSSelectorFromString(@"gradientEndPoint"));
        d[@"start"] = @[@(sp.x), @(sp.y)];
        d[@"end"] = @[@(ep.x), @(ep.y)];
    }
    return d;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        // Flat framework path works on both macOS (top-level symlink) and iOS (flat layout).
        dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW);
        void *svg = dlopen("/System/Library/PrivateFrameworks/CoreSVG.framework/CoreSVG", RTLD_NOW);
        CGSVGDocumentWriteToURL_ = dlsym(svg, "CGSVGDocumentWriteToURL");
        NSString *carPath = argc > 1 ? @(argv[1]) : @"/System/Applications/App Store.app/Contents/Resources/Assets.car";
        NSString *iconName = argc > 2 ? @(argv[2]) : @"AppIcon";
        NSString *outDir = argc > 3 ? @(argv[3]) : [@"~/Desktop/AppStoreIcon-extract" stringByExpandingTildeInPath];
        [[NSFileManager defaultManager] createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *err = nil;
        CUICatalog *cat = [[NSClassFromString(@"CUICatalog") alloc] initWithURL:[NSURL fileURLWithPath:carPath] error:&err];
        if (!cat) { fprintf(stderr, "catalog open failed: %s\n", err.description.UTF8String); return 1; }

        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        // macOS icons use NSAppearanceName*; iOS icons use UIAppearance* and a nil/light default.
        // NSNull marks the nil ("default light") lookup; keyed as "Default" in output.
        NSArray *appearances = @[@"NSAppearanceNameAqua", @"NSAppearanceNameDarkAqua",
                                 @"ISAppearanceTintable", @"UIAppearanceAny", @"UIAppearanceDark",
                                 [NSNull null], @"UIAppearanceLight"];
        for (id appObj in appearances) {
            NSString *app = [appObj isKindOfClass:[NSNull class]] ? nil : appObj;
            NSString *key = app ?: @"Default";
            if (result[key]) continue;  // avoid dup if a name resolves to same as Default
            id stack = [cat iconLayerStackWithName:iconName scaleFactor:1 deviceIdiom:0 deviceSubtype:0 displayGamut:0 appearanceName:app locale:nil];
            if (!stack) { result[key] = @"NOT FOUND"; continue; }
            NSMutableDictionary *sd = [NSMutableDictionary dictionary];
            sd[@"class"] = NSStringFromClass([stack class]);
            id rp = val(stack, @"renderingProperties");
            if (rp) sd[@"renderingProperties"] = [rp description];
            if ([stack respondsToSelector:NSSelectorFromString(@"dataRepresentationWithError:")]) {
                NSError *e2 = nil;
                NSData *data = ((NSData *(*)(id, SEL, NSError **))objc_msgSend)(stack, NSSelectorFromString(@"dataRepresentationWithError:"), &e2);
                if (data) {
                    NSString *fn = [NSString stringWithFormat:@"%@__%@.dataRep", iconName, key];
                    [data writeToFile:[outDir stringByAppendingPathComponent:fn] atomically:YES];
                    sd[@"dataRepFile"] = fn;
                }
            }
            NSArray *groups = val(stack, @"layers");
            // The canvas background fill is a leading CUINamedGradient/Color in the
            // stack (before the first icon-layer group). Resolve it per appearance.
            for (id g in groups) {
                NSString *gcls = NSStringFromClass([g class]);
                if ([gcls containsString:@"LayerGroup"]) break;  // reached real layers
                if ([gcls containsString:@"Gradient"]) {
                    sd[@"canvasFill"] = resolveGradient(g, cat, app);
                    break;
                }
                if ([gcls containsString:@"Color"]) {
                    // CUINamedColor exposes -cgColor (already resolved for this appearance).
                    CGColorRef cc = NULL;
                    if ([g respondsToSelector:NSSelectorFromString(@"cgColor")])
                        cc = ((CGColorRef (*)(id, SEL))objc_msgSend)(g, NSSelectorFromString(@"cgColor"));
                    if (cc) sd[@"canvasFill"] = @{ @"colors": @[colorJSON(cc)] };
                    break;
                }
            }
            NSMutableArray *gd = [NSMutableArray array];
            for (id g in groups) [gd addObject:dumpLayer(g, outDir, key)];
            sd[@"groups"] = gd;
            result[key] = sd;
        }

        // Capture the canvas background gradient(s). Layered icons store it as
        // named gradients "<prefix>/system-light" and "system-dark".
        @try {
            NSMutableArray *bgLookups = [NSMutableArray array];
            [cat enumerateNamedLookupsUsingBlock:^(id lk) {
                NSString *nm = val(lk, @"name");
                if (nm && [nm containsString:@"system-"]) [bgLookups addObject:lk];
            }];
            NSMutableDictionary *bg = [NSMutableDictionary dictionary];
            for (id lk in bgLookups) {
                NSString *nm = val(lk, @"name");
                NSString *leaf = [nm componentsSeparatedByString:@"/"].lastObject; // system-light/dark/any
                NSMutableDictionary *byApp = [NSMutableDictionary dictionary];
                for (NSString *app in @[@"UIAppearanceLight", @"UIAppearanceDark"]) {
                    NSDictionary *g = resolveGradient(lk, cat, app);
                    if (g.count) byApp[app] = g;
                }
                if (byApp.count) bg[leaf] = byApp;
            }
            if (bg.count) result[@"_background"] = bg;
        } @catch (NSException *ex) { /* background is best-effort */ }

        {
            NSError *we=nil;
            NSData *j0=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&we];
            if (!j0) { fprintf(stderr, "json fail: %s\n", we.description.UTF8String); return 1; }
            [j0 writeToFile:[outDir stringByAppendingPathComponent:@"extracted.json"] atomically:YES];
        }
        printf("done -> %s\n", outDir.UTF8String);
    }
    return 0;
}
