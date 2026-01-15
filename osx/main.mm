#include "main.hpp"
#include "../constant.hpp"
#include "../keyboard.hpp"
#include "../platform_api.hpp"
#include "../util.hpp"
#include "../viewer.hpp"
#include "alert_window.hpp"
#include "menu.hpp"
#include "window.hpp"
#include <QuartzCore/QuartzCore.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSArray *argsArray = [[NSProcessInfo processInfo] arguments];
    std::vector<std::string> argsVec;
    for (const NSString *arg in argsArray) {
        argsVec.push_back([arg UTF8String]);
    }
    const auto cmdArgs = CmdArgs::Parse(argsVec);

    auto appMain = getAppMain();
    auto& routine = [appMain getRoutine];
    routine.ParseConfig(cmdArgs);
    [appMain createMainWindow];
    [appMain createStatusItem];

    routine.Init();

    [appMain startDrawingModel];
}
- (void)applicationWillTerminate:(NSNotification *)aNotification {
    [getAppMain() getRoutine].Terminate();
}
@end

@implementation AppMain {
    Window *window_;
    WindowDelegate *windowDelegate_;
    View *view_;
    id<MTLDevice> metalDevice_;
    ViewDelegate *viewDelegate_;
    NSStatusItem *statusItem_;
    NSMenu *appMenu_;
    AppMenuDelegate *appMenuDelegate_;
    Routine routine_;
}
- (void)createMainWindow {
    // Initial window size and position
    const float kNotchWidth = 300.0f;
    const float kNotchHeight = 44.0f;
    
    NSRect screenRect = [NSScreen mainScreen].frame;
    NSRect initialRect = NSMakeRect(
        (screenRect.size.width - kNotchWidth) / 2.0,
        screenRect.size.height - kNotchHeight,
        kNotchWidth,
        kNotchHeight
    );

    window_ = [[Window alloc] initWithContentRect:initialRect
                                        styleMask:NSWindowStyleMaskBorderless
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
    windowDelegate_ = [[WindowDelegate alloc] init];

    [window_ setDelegate:windowDelegate_];
    [window_ setTitle:@"yoMMD"];
    
    [window_ setCollectionBehavior: NSWindowCollectionBehaviorCanJoinAllSpaces | 
                                    NSWindowCollectionBehaviorStationary | 
                                    NSWindowCollectionBehaviorFullScreenAuxiliary];

    [window_ setIsVisible:YES];
    [window_ setOpaque:NO];
    [window_ setBackgroundColor:[NSColor clearColor]];
    [window_ setHasShadow:NO];
    [window_ setLevel:NSMainMenuWindowLevel + 2];
    [window_ setIgnoresMouseEvents:NO];

    viewDelegate_ = [[ViewDelegate alloc] init];
    metalDevice_ = MTLCreateSystemDefaultDevice();
    
    // View container
    NSView *containerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kNotchWidth, kNotchHeight)];
    [containerView setWantsLayer:YES];
    containerView.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    containerView.layer.masksToBounds = YES;
    if (@available(macOS 10.15, *)) {
        containerView.layer.cornerCurve = kCACornerCurveContinuous;
    }

    view_ = [[View alloc] initWithFrame:containerView.bounds];
    [view_ setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [view_ setPreferredFramesPerSecond:static_cast<NSInteger>(Constant::FPS)];
    [view_ setDevice:metalDevice_];
    [view_ setColorPixelFormat:MTLPixelFormatBGRA8Unorm];
    [view_ setDepthStencilPixelFormat:MTLPixelFormatDepth32Float_Stencil8];
    [view_ setSampleCount:static_cast<NSUInteger>(Constant::PreferredSampleCount)];
    
    [containerView addSubview:view_];

    [window_ setContentView:containerView];

    // HACK: Forced initial frame to avoid auto-resize issues
    [window_ setFrame:initialRect display:YES];
    containerView.layer.cornerRadius = kNotchHeight / 2.0;
    containerView.layer.masksToBounds = YES;
}

- (void)createStatusItem {
    const auto iconData = Resource::getStatusIconData();
    NSData *nsIconData = [NSData dataWithBytes:iconData.data() length:iconData.length()];
    NSImage *icon = [[NSImage alloc] initWithData:nsIconData];
    statusItem_ =
        [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    [statusItem_.button setImage:icon];
    [statusItem_ setBehavior:NSStatusItemBehaviorTerminationOnRemoval];
    [statusItem_ setVisible:YES];

    appMenuDelegate_ = [[AppMenuDelegate alloc] init];
    appMenu_ = [[NSMenu alloc] init];
    [appMenu_ setDelegate:appMenuDelegate_];
    [statusItem_ setMenu:appMenu_];
}
- (void)setIgnoreMouse:(bool)enable {
    [window_ setIgnoresMouseEvents:enable];
    if (!enable)
        Keyboard::ResetAllState();
}
- (bool)getIgnoreMouse {
    return [window_ ignoresMouseEvents];
}
- (void)changeWindowScreen:(NSUInteger)scID {
    const NSScreen *dst = findScreenFromID(scID);
    if (!dst) {
        Info::Log("Display not found: %ld", scID);
        return;
    }
    // remaining at the top center of the target screen
    NSRect frame = window_.frame;
    NSRect screenFrame = dst.frame;
    frame.origin.x = screenFrame.origin.x + (screenFrame.size.width - frame.size.width) / 2.0;
    frame.origin.y = screenFrame.origin.y + screenFrame.size.height - frame.size.height;
    [window_ setFrame:frame display:YES animate:NO];
}
- (NSMenu *)getAppMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    [menu setDelegate:appMenuDelegate_];
    return menu;
}
- (sg_environment)getSokolEnvironment {
    return sg_environment{
        .defaults =
            {
                .color_format = SG_PIXELFORMAT_BGRA8,
                .depth_format = SG_PIXELFORMAT_DEPTH_STENCIL,
                .sample_count = Constant::PreferredSampleCount,
            },
        .metal =
            {
                .device = (__bridge const void *)metalDevice_,
            },
    };
}
- (sg_swapchain)getSokolSwapchain {
    const auto size{Context::getWindowSize()};
    return sg_swapchain{
        .width = static_cast<int>(size.x),
        .height = static_cast<int>(size.y),
        .sample_count = Constant::PreferredSampleCount,
        .color_format = SG_PIXELFORMAT_BGRA8,
        .depth_format = SG_PIXELFORMAT_DEPTH_STENCIL,
        .metal =
            {
                .current_drawable = (__bridge const void *)[view_ currentDrawable],
                .depth_stencil_texture = (__bridge const void *)[view_ depthStencilTexture],
                .msaa_color_texture = (__bridge const void *)[view_ multisampleColorTexture],
            },
    };
}
- (NSSize)getWindowSize {
    return window_.frame.size;
}
- (NSPoint)getWindowPosition {
    return window_.frame.origin;
}
- (NSSize)getDrawableSize {
    return view_.drawableSize;
}
- (NSNumber *)getCurrentScreenNumber {
    const NSScreen *screen = [window_ screen];
    if (!screen)
        Err::Log("Internal error? screen is offscreen");
    return [screen deviceDescription][@"NSScreenNumber"];
}
- (bool)isMenuOpened {
    return [appMenuDelegate_ isMenuOpened];
}
- (Routine&)getRoutine {
    return routine_;
}
- (void)startDrawingModel {
    [view_ setDelegate:viewDelegate_];
}
@end

AppMain *getAppMain(void) {
    static AppMain *appMain = [[AppMain alloc] init];
    return appMain;
}

NSScreen *findScreenFromID(NSInteger scID) {
    NSNumber *target = [[NSNumber alloc] initWithInteger:scID];
    for (NSScreen *sc in [NSScreen screens]) {
        NSNumber *scNum = [sc deviceDescription][@"NSScreenNumber"];
        if ([scNum isEqualToNumber:target]) {
            return sc;
        }
    }
    return nil;
}

sg_environment Context::getSokolEnvironment() {
    return [getAppMain() getSokolEnvironment];
}

sg_swapchain Context::getSokolSwapchain() {
    return [getAppMain() getSokolSwapchain];
}

glm::vec2 Context::getWindowSize() {
    const auto size = [getAppMain() getWindowSize];
    return glm::vec2(size.width, size.height);
}

glm::vec2 Context::getDrawableSize() {
    const auto size = [getAppMain() getDrawableSize];
    return glm::vec2(size.width, size.height);
}

glm::vec2 Context::getMousePosition() {
    const auto pos = [NSEvent mouseLocation];
    const auto origin = [getAppMain() getWindowPosition];
    return glm::vec2(pos.x - origin.x, pos.y - origin.y);
}

int Context::getSampleCount() {
    return Constant::PreferredSampleCount;
}

bool Context::shouldEmphasizeModel() {
    return [getAppMain() isMenuOpened];
}

namespace Dialog {
void messageBox(std::string_view msg) {
    static AlertWindow *window;

    window = [AlertWindow alloc];
    [window showAlert:[NSString stringWithUTF8String:msg.data()]];
}
}  // namespace Dialog

int main() {
    [NSApplication sharedApplication];

    auto appDelegate = [[AppDelegate alloc] init];

    [NSApp setDelegate:appDelegate];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp activateIgnoringOtherApps:NO];
    [NSApp run];
}
