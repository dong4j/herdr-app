// AppKit ownership and coordinate adapter for the original Magpie web page.
// Rendering, routing decisions, CSS and animation remain Magpie's own code.
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#include <sys/stat.h>
#import <objc/runtime.h>

// Retains the native page and its delegates for exactly one Herdr window.
@interface HerdrRoutingPage : NSObject <WKNavigationDelegate, WKUIDelegate>
@property(nonatomic, strong) WKWebView *web;
@property(nonatomic) BOOL visible;
@end

@implementation HerdrRoutingPage
- (void)webView:(WKWebView *)web didFinishNavigation:(WKNavigation *)navigation {
    [web evaluateJavaScript:self.visible ? @"window.magpieWindowVisibility?.(true)" : @"window.magpieWindowVisibility?.(false)" completionHandler:nil];
}
- (WKWebView *)webView:(WKWebView *)web createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
    // Magpie's web mode opens its detail pages and links in a new tab. Keep
    // local Magpie pages in this container; external links use the browser.
    NSURL *url = action.request.URL;
    if ([url.host isEqualToString:web.URL.host] && [url.port isEqual:web.URL.port]) [web loadRequest:action.request];
    else if (url) [[NSWorkspace sharedWorkspace] openURL:url];
    return nil;
}
@end

// AccessKit replaces the GPUI view's AX children and hit testing with its
// virtual tree. Include this real child as well, otherwise VoiceOver and
// coordinate-based automation cannot reach the original page's controls.
static char routingPageKey;
static IMP originalChildren;
static IMP originalHitTest;
static Class accessibilityHostClass;

static NSArray *routingChildren(NSView *parent, SEL selector) {
    NSArray *base = ((id (*)(id, SEL))originalChildren)(parent, selector);
    HerdrRoutingPage *page = objc_getAssociatedObject(parent, &routingPageKey);
    if (!page || page.web.hidden) return base;
    return [(base ?: @[]) arrayByAddingObjectsFromArray:NSAccessibilityUnignoredChildren(@[page.web])];
}

static id routingHitTest(NSView *parent, SEL selector, NSPoint screenPoint) {
    HerdrRoutingPage *page = objc_getAssociatedObject(parent, &routingPageKey);
    if (page && !page.web.hidden) {
        NSPoint point = [page.web convertPoint:[parent.window convertPointFromScreen:screenPoint] fromView:nil];
        if (NSPointInRect(point, page.web.bounds)) return [page.web accessibilityHitTest:screenPoint];
    }
    return ((id (*)(id, SEL, NSPoint))originalHitTest)(parent, selector, screenPoint);
}

static void exposeNativePage(NSView *parent, HerdrRoutingPage *page) {
    if (!accessibilityHostClass) {
        accessibilityHostClass = object_getClass(parent);
        SEL children = @selector(accessibilityChildren);
        SEL hit = @selector(accessibilityHitTest:);
        Method childrenMethod = class_getInstanceMethod(accessibilityHostClass, children);
        Method hitMethod = class_getInstanceMethod(accessibilityHostClass, hit);
        originalChildren = method_getImplementation(childrenMethod);
        originalHitTest = method_getImplementation(hitMethod);
        class_replaceMethod(accessibilityHostClass, children, (IMP)routingChildren, method_getTypeEncoding(childrenMethod));
        class_replaceMethod(accessibilityHostClass, hit, (IMP)routingHitTest, method_getTypeEncoding(hitMethod));
    }
    // The window owns the parent; RoutingView releases the page and clears
    // this association before its retained native child is detached.
    objc_setAssociatedObject(parent, &routingPageKey, page, OBJC_ASSOCIATION_ASSIGN);
}

// The host removes only Magpie's outer app navigation. Every Routing rule,
// stage, account row, context card, history control and animation is untouched.
static NSString *const adapter =
@"(() => {"
"window.__herdrRoutingErrors = [];"
"addEventListener('error', e => window.__herdrRoutingErrors.push(String(e.message)));"
"addEventListener('unhandledrejection', e => window.__herdrRoutingErrors.push(String(e.reason)));"
"const style = document.createElement('style');"
"style.textContent = 'header.top, .sidebar, #ptabs { display: none !important; } body.side-nav { padding-left: 0 !important; }';"
"document.documentElement.append(style);"
"})();";

void *herdr_routing_create(void *parentPointer, const char *url) {
    NSCAssert([NSThread isMainThread], @"WKWebView must be created on the main thread");
    NSView *parent = (__bridge NSView *)parentPointer;
    HerdrRoutingPage *page = [HerdrRoutingPage new];
    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    // A separate nonpersistent store keeps Magpie's sign-in cookie away from
    // the user's browser and from other windows' randomly allocated ports.
    config.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:adapter injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES]];
    page.web = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:config];
    page.web.navigationDelegate = page;
    page.web.UIDelegate = page;
    page.web.hidden = YES;
    page.web.wantsLayer = YES;
    page.web.layer.cornerRadius = 10;
    page.web.layer.masksToBounds = YES;
    if (@available(macOS 13.3, *)) page.web.inspectable = YES;
    [parent addSubview:page.web];
    // GPUI renders in an inner view; AccessKit subclasses the outer content view.
    exposeNativePage(parent.window.contentView ?: parent, page);
    [page.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithUTF8String:url]]]];
    return (__bridge_retained void *)page;
}

void herdr_routing_bounds(void *handle, double x, double y, double width, double height) {
    HerdrRoutingPage *page = (__bridge HerdrRoutingPage *)handle;
    NSView *parent = page.web.superview;
    // GPUI's canvas is top-left; an unflipped NSView's origin is bottom-left.
    NSRect frame = NSMakeRect(x, parent.isFlipped ? y : parent.bounds.size.height - y - height, width, height);
    if (!NSEqualRects(frame, page.web.frame)) page.web.frame = frame;
}

void herdr_routing_visible(void *handle, bool visible) {
    HerdrRoutingPage *page = (__bridge HerdrRoutingPage *)handle;
    if (page.visible == visible && page.web.hidden == !visible) return;
    page.visible = visible;
    page.web.hidden = !visible;
    [page.web evaluateJavaScript:visible ? @"window.magpieWindowVisibility?.(true)" : @"window.magpieWindowVisibility?.(false)" completionHandler:nil];
    if (!visible && [page.web.window.firstResponder isKindOfClass:NSView.class] && [(NSView *)page.web.window.firstResponder isDescendantOf:page.web]) {
        [page.web.window makeFirstResponder:page.web.superview];
    }
}

void herdr_routing_release(void *handle) {
    HerdrRoutingPage *page = (__bridge_transfer HerdrRoutingPage *)handle;
    objc_setAssociatedObject(page.web.window.contentView ?: page.web.superview, &routingPageKey, nil, OBJC_ASSOCIATION_ASSIGN);
    [page.web stopLoading];
    page.web.navigationDelegate = nil;
    page.web.UIDelegate = nil;
    [page.web removeFromSuperview];
}

// Inspection is explicit, not a frame timer. It verifies the original DOM,
// resources and moving SVG transforms without persisting request bodies.
void herdr_routing_inspect(void *handle, const char *path) {
    HerdrRoutingPage *page = (__bridge HerdrRoutingPage *)handle;
    NSString *destination = [NSString stringWithUTF8String:path];
    NSString *script = @"JSON.stringify({title:document.title,hidden:document.hidden,ready:!!document.querySelector('#rt .rt-stage'),rows:document.querySelectorAll('.rt-req').length,context:!!document.querySelector('.rt-ctx'),errors:window.__herdrRoutingErrors,assets:performance.getEntriesByType('resource').filter(x=>/routing|context/.test(x.name)).map(x=>new URL(x.name).pathname),flights:[...document.querySelectorAll('.rt-sky .rt-flier')].map(x=>x.getAttribute('transform')),stage:document.querySelector('.rt-stage')?.getBoundingClientRect().toJSON()})";
    [page.web evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        NSString *json = [result isKindOfClass:NSString.class] ? result : @"{\"error\":\"WebKit inspection failed\"}";
        [json writeToFile:destination atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod(destination.fileSystemRepresentation, 0600);
    }];
    [page.web takeSnapshotWithConfiguration:nil completionHandler:^(NSImage *image, NSError *error) {
        if (!image || error) return;
        NSBitmapImageRep *pixels = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
        NSData *png = [pixels representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSString *picture = [[destination stringByDeletingPathExtension] stringByAppendingPathExtension:@"png"];
        [png writeToFile:picture atomically:YES];
        chmod(picture.fileSystemRepresentation, 0600);
    }];
}
