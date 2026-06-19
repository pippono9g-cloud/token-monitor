#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@interface AppDelegate : NSObject <NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSTimer *statusTimer;
@property(nonatomic, strong) WKWebView *claudeWebView;
@property(nonatomic, strong) NSWindow *claudeLoginWindow;
@property(nonatomic, assign) BOOL claudeWebViewPendingRead;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
  WKUserContentController *contentController = [[WKUserContentController alloc] init];
  [contentController addScriptMessageHandler:self name:@"claudeUsage"];
  [contentController addScriptMessageHandler:self name:@"claudeAppUsage"];
  [contentController addScriptMessageHandler:self name:@"closeWindow"];
  configuration.userContentController = contentController;

  self.webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:configuration];
  self.webView.navigationDelegate = self;

  NSRect frame = NSMakeRect(0, 0, 327, 220);
  NSWindowStyleMask style = NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable |
                            NSWindowStyleMaskResizable;

  self.window = [[NSWindow alloc] initWithContentRect:frame
                                            styleMask:style
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
  [self.window center];
  [self.window setTitle:@"Token Monitor"];
  [self.window setMinSize:NSMakeSize(280, 180)];
  [self.window setContentView:self.webView];
  [self.window orderOut:nil];

  [self setupStatusItem];

  [self loadApp];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
  return NO;
}

- (void)loadApp {
  NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
  NSURL *appURL = [NSURL fileURLWithPath:[resourcePath stringByAppendingPathComponent:@"index.html"]];
  NSURL *directoryURL = [appURL URLByDeletingLastPathComponent];
  [self.webView loadFileURL:appURL allowingReadAccessToURL:directoryURL];
}

- (void)setupStatusItem {
  self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
  self.statusItem.button.image = nil;
  self.statusItem.button.imagePosition = NSNoImage;
  [self updateStatusIconWithDailyPercent:0 weeklyPercent:0];
  self.statusItem.button.toolTip = @"Token Monitor";
  self.statusItem.button.target = self;
  self.statusItem.button.action = @selector(toggleWindow:);
  [self.statusItem.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];

  self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                      target:self
                                                    selector:@selector(refreshStatusItem)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void)toggleWindow:(id)sender {
  NSEvent *event = [NSApp currentEvent];
  if (event.type == NSEventTypeRightMouseUp) {
    [self showMenu];
    return;
  }

  if (self.window.isVisible) {
    [self.window orderOut:nil];
    return;
  }

  [NSApp activateIgnoringOtherApps:YES];
  [self.window makeKeyAndOrderFront:nil];
  [self refreshStatusItem];
}

- (void)showMenu {
  NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Token Monitor"];
  [menu addItemWithTitle:@"Open Token Monitor" action:@selector(openWindowFromMenu:) keyEquivalent:@""];
  [menu addItemWithTitle:@"Refresh" action:@selector(refreshFromMenu:) keyEquivalent:@"r"];
  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItemWithTitle:@"Quit" action:@selector(quitFromMenu:) keyEquivalent:@"q"];
  self.statusItem.menu = menu;
  [self.statusItem.button performClick:nil];
  self.statusItem.menu = nil;
}

- (void)openWindowFromMenu:(id)sender {
  [NSApp activateIgnoringOtherApps:YES];
  [self.window makeKeyAndOrderFront:nil];
}

- (void)refreshFromMenu:(id)sender {
  [self readClaudeDesktopUsage];
}

- (void)quitFromMenu:(id)sender {
  [NSApp terminate:nil];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
  if (webView == self.claudeWebView) {
    [self handleClaudeWebViewDidLoad];
    return;
  }
  [self refreshStatusItem];
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
  if ([message.name isEqualToString:@"closeWindow"]) {
    [NSApp terminate:nil];
    return;
  }

  if ([message.name isEqualToString:@"claudeAppUsage"]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self readClaudeDesktopUsage];
    });
    return;
  }

  if (![message.name isEqualToString:@"claudeUsage"] || ![message.body isKindOfClass:[NSDictionary class]]) {
    return;
  }

  NSDictionary *body = (NSDictionary *)message.body;
  NSString *apiKey = body[@"apiKey"];
  NSString *startIso = body[@"startIso"];
  NSString *endIso = body[@"endIso"];

  if (apiKey.length == 0 || startIso.length == 0 || endIso.length == 0) {
    [self reportClaudeSyncError:@"Missing Claude API sync settings."];
    return;
  }

  [self fetchClaudeUsageWithAPIKey:apiKey startIso:startIso endIso:endIso];
}

- (void)readClaudeDesktopUsage {
  if (!self.claudeWebView) {
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
    self.claudeWebView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 960, 700) configuration:config];
    self.claudeWebView.navigationDelegate = self;
  }
  self.claudeWebViewPendingRead = YES;
  NSURL *url = [NSURL URLWithString:@"https://claude.ai/settings/usage"];
  NSURLRequest *req = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
  [self.claudeWebView loadRequest:req];
}

- (void)handleClaudeWebViewDidLoad {
  NSString *urlStr = self.claudeWebView.URL.absoluteString ?: @"";

  BOOL isLoginPage = [urlStr containsString:@"/login"] || [urlStr containsString:@"/auth"] ||
      [urlStr containsString:@"/sign-in"] || [urlStr containsString:@"/signup"] ||
      [urlStr isEqualToString:@"https://claude.ai/"] || [urlStr isEqualToString:@"https://claude.ai"];
  if (isLoginPage) {
    [self showClaudeLoginWindow];
    [self reportClaudeSyncError:@"Log in to Claude in the window that opened, then click Refresh."];
    return;
  }

  if (!self.claudeWebViewPendingRead) return;

  [self scheduleClaudeExtractWithRetry:0];
}

- (void)scheduleClaudeExtractWithRetry:(NSInteger)attempt {
  NSArray *delays = @[@2.5, @4.0, @6.0, @9.0];
  if (attempt >= (NSInteger)delays.count) return;
  double delay = [delays[attempt] doubleValue];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    if (!self.claudeWebViewPendingRead && attempt == 0) return;
    NSString *js = @"document.body ? document.body.innerText : ''";
    [self.claudeWebView evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
      if (error || ![result isKindOfClass:[NSString class]]) return;
      NSString *text = (NSString *)result;
      NSDictionary *usage = [self parseClaudeUsageFromText:text];
      if (usage) {
        self.claudeWebViewPendingRead = NO;
        [self.claudeLoginWindow orderOut:nil];
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:usage options:0 error:nil];
        NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        NSString *script = [NSString stringWithFormat:@"window.applyClaudeAppUsage(%@);", json];
        [self.webView evaluateJavaScript:script completionHandler:^(id r, NSError *e) {
          if (!e) [self refreshStatusItem];
        }];
      } else {
        [self scheduleClaudeExtractWithRetry:attempt + 1];
        if (attempt >= (NSInteger)delays.count - 2) {
          [self showClaudeLoginWindow];
          [self reportClaudeSyncError:@"Could not read usage values. Make sure the Usage page loaded, then click Refresh."];
        }
      }
    }];
  });
}

- (void)showClaudeLoginWindow {
  if (!self.claudeLoginWindow) {
    self.claudeLoginWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 960, 700)
                                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                           backing:NSBackingStoreBuffered
                                                             defer:NO];
    [self.claudeLoginWindow setTitle:@"Log in to Claude"];
    [self.claudeLoginWindow setContentView:self.claudeWebView];
    [self.claudeLoginWindow center];
    [self.claudeLoginWindow setMinSize:NSMakeSize(480, 500)];
  }
  [NSApp activateIgnoringOtherApps:YES];
  [self.claudeLoginWindow makeKeyAndOrderFront:nil];
}

- (void)extractClaudeUsageFromWebView {
  self.claudeWebViewPendingRead = NO;
  NSString *js = @"document.body ? document.body.innerText : ''";
  [self.claudeWebView evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
    if (error || ![result isKindOfClass:[NSString class]]) {
      [self reportClaudeSyncError:@"Could not read Claude usage page."];
      return;
    }
    NSString *text = (NSString *)result;
    NSLog(@"[TokenMonitor] claude.ai page text (first 800 chars):\n%@",
          text.length > 800 ? [text substringToIndex:800] : text);
    NSDictionary *usage = [self parseClaudeUsageFromText:text];
    if (!usage) {
      [self showClaudeLoginWindow];
      [self reportClaudeSyncError:@"Could not read usage values. Log in and make sure the Usage page loaded, then click Refresh."];
      return;
    }
    [self.claudeLoginWindow orderOut:nil];
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:usage options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSString *script = [NSString stringWithFormat:@"window.applyClaudeAppUsage(%@);", json];
    [self.webView evaluateJavaScript:script completionHandler:^(id r, NSError *e) {
      if (e) {
        [self reportClaudeSyncError:[NSString stringWithFormat:@"Could not apply Claude usage: %@", e.localizedDescription]];
      } else {
        [self refreshStatusItem];
      }
    }];
  }];
}

- (NSDictionary *)parseClaudeUsageFromText:(NSString *)text {
  // Try "X% used" first, then fallback to "X% of" or "X%\n"
  NSArray *patterns = @[
    @"(\\d{1,3})\\s*%\\s*used",
    @"(\\d{1,3})\\s*%\\s*of",
    @"(\\d{1,3})%"
  ];
  NSArray<NSTextCheckingResult *> *matches = nil;
  for (NSString *pattern in patterns) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    matches = [re matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    if (matches.count >= 2) break;
  }
  if (matches.count < 2) return nil;

  NSInteger sessionPercent = [[text substringWithRange:[matches[0] rangeAtIndex:1]] integerValue];
  NSInteger weeklyPercent = [[text substringWithRange:[matches[1] rangeAtIndex:1]] integerValue];
  NSString *weeklyReset = @"Fri 12:59 AM";

  NSRegularExpression *resetRegex = [NSRegularExpression regularExpressionWithPattern:@"Resets\\s+([A-Za-z]{3}\\s+\\d{1,2}:\\d{2}\\s+[AP]M)" options:0 error:nil];
  NSTextCheckingResult *resetMatch = [resetRegex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
  if (resetMatch && resetMatch.numberOfRanges > 1) {
    weeklyReset = [text substringWithRange:[resetMatch rangeAtIndex:1]];
  }

  return @{@"sessionPercent": @(sessionPercent), @"weeklyPercent": @(weeklyPercent), @"weeklyReset": weeklyReset};
}


- (void)fetchClaudeUsageWithAPIKey:(NSString *)apiKey startIso:(NSString *)startIso endIso:(NSString *)endIso {
  NSURLComponents *components = [NSURLComponents componentsWithString:@"https://api.anthropic.com/v1/organizations/usage_report/messages"];
  components.queryItems = @[
    [NSURLQueryItem queryItemWithName:@"starting_at" value:startIso],
    [NSURLQueryItem queryItemWithName:@"ending_at" value:endIso],
    [NSURLQueryItem queryItemWithName:@"bucket_width" value:@"1d"]
  ];

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
  request.HTTPMethod = @"GET";
  [request setValue:apiKey forHTTPHeaderField:@"x-api-key"];
  [request setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];

  NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    if (error) {
      [self reportClaudeSyncError:[NSString stringWithFormat:@"Claude sync failed: %@", error.localizedDescription]];
      return;
    }

    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
      NSString *message = [NSString stringWithFormat:@"Claude API returned %ld.", (long)httpResponse.statusCode];
      [self reportClaudeSyncError:message];
      return;
    }

    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (json.length == 0) {
      [self reportClaudeSyncError:@"Claude API returned an empty response."];
      return;
    }

    NSString *script = [NSString stringWithFormat:@"window.importClaudeUsage(window.extractClaudeUsageEntries(%@), { message: 'Imported from Anthropic usage API.' });", json];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *scriptError) {
        if (scriptError) {
          [self reportClaudeSyncError:[NSString stringWithFormat:@"Claude import failed: %@", scriptError.localizedDescription]];
        } else {
          [self refreshStatusItem];
        }
      }];
    });
  }];
  [task resume];
}

- (void)reportClaudeSyncError:(NSString *)message {
  NSData *data = [NSJSONSerialization dataWithJSONObject:@[message ?: @"Claude sync failed."] options:0 error:nil];
  NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"[\"Claude sync failed.\"]";
  NSString *script = [NSString stringWithFormat:@"window.reportClaudeSyncError(%@[0]);", json];
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.webView evaluateJavaScript:script completionHandler:nil];
  });
}

- (void)refreshStatusItem {
  NSString *script = @"JSON.stringify(window.TokenMonitorStatus ? window.TokenMonitorStatus() : null)";
  [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
    if (error || ![result isKindOfClass:[NSString class]]) {
      return;
    }

    NSData *data = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) {
      return;
    }

    NSDictionary *status = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![status isKindOfClass:[NSDictionary class]]) {
      return;
    }

    double dailyPercent = [status[@"dailyPercent"] doubleValue];
    double weeklyPercent = [status[@"weeklyPercent"] doubleValue];
    NSString *dailyReset = status[@"nextDailyReset"] ?: @"";
    NSString *weeklyReset = status[@"nextWeeklyReset"] ?: @"";

    dispatch_async(dispatch_get_main_queue(), ^{
      [self updateStatusIconWithDailyPercent:dailyPercent weeklyPercent:weeklyPercent];
      [self updateDockIconWithDailyPercent:dailyPercent weeklyPercent:weeklyPercent];
      self.statusItem.button.toolTip = [NSString stringWithFormat:@"Daily %.1f%% · reset %@\nWeekly %.1f%% · reset %@",
                                        dailyPercent,
                                        dailyReset,
                                        weeklyPercent,
                                        weeklyReset];
    });
  }];
}

- (void)updateDockIconWithDailyPercent:(double)dailyPercent weeklyPercent:(double)weeklyPercent {
  CGFloat size = 512;
  NSImage *icon = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
  [icon lockFocus];

  // Background: dark rounded square
  NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, size, size)
                                                     xRadius:size * 0.22
                                                     yRadius:size * 0.22];
  [[NSColor colorWithRed:0.10 green:0.10 blue:0.12 alpha:1.0] setFill];
  [bg fill];

  // Claude logo: 4 elongated petals at 0°, 45°, 90°, 135°
  CGFloat cx = size / 2;
  CGFloat cy = size * 0.60;
  CGFloat petalLen = size * 0.28;
  CGFloat petalW = size * 0.065;
  [[NSColor whiteColor] setFill];
  for (int i = 0; i < 4; i++) {
    CGFloat angle = i * M_PI / 4.0;
    NSAffineTransform *t = [NSAffineTransform transform];
    [t translateXBy:cx yBy:cy];
    [t rotateByRadians:angle];
    NSBezierPath *petal = [NSBezierPath bezierPath];
    [petal moveToPoint:NSMakePoint(0, petalLen)];
    [petal curveToPoint:NSMakePoint(0, -petalLen)
         controlPoint1:NSMakePoint(petalW, petalLen * 0.4)
         controlPoint2:NSMakePoint(petalW, -petalLen * 0.4)];
    [petal curveToPoint:NSMakePoint(0, petalLen)
         controlPoint1:NSMakePoint(-petalW, -petalLen * 0.4)
         controlPoint2:NSMakePoint(-petalW, petalLen * 0.4)];
    [petal closePath];
    NSBezierPath *transformed = [NSBezierPath bezierPath];
    [transformed appendBezierPath:petal];
    NSAffineTransform *apply = [NSAffineTransform transform];
    [apply translateXBy:cx yBy:cy];
    [apply rotateByRadians:angle];
    NSBezierPath *final = [apply transformBezierPath:petal];
    [final fill];
  }

  // Percentage text below sparkle
  NSString *percentText = [NSString stringWithFormat:@"%d%%", (int)round(dailyPercent)];
  NSFont *percentFont = [NSFont systemFontOfSize:size * 0.16 weight:NSFontWeightSemibold];
  NSDictionary *percentAttrs = @{
    NSFontAttributeName: percentFont,
    NSForegroundColorAttributeName: [NSColor colorWithWhite:0.75 alpha:1.0]
  };
  NSAttributedString *percentStr = [[NSAttributedString alloc] initWithString:percentText attributes:percentAttrs];
  CGSize percentSize = [percentStr size];
  [percentStr drawAtPoint:NSMakePoint((size - percentSize.width) / 2, size * 0.14)];

  [icon unlockFocus];
  [NSApp setApplicationIconImage:icon];
}

- (void)updateStatusIconWithDailyPercent:(double)dailyPercent weeklyPercent:(double)weeklyPercent {
  NSInteger dailyBlocks = (NSInteger)round(fmin(100.0, fmax(0.0, dailyPercent)) / 10.0);
  NSInteger weeklyBlocks = (NSInteger)round(fmin(100.0, fmax(0.0, weeklyPercent)) / 10.0);

  NSFont *font = [NSFont monospacedSystemFontOfSize:5.0 weight:NSFontWeightMedium];
  NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] init];

  for (NSString *label in @[@"D", @"W"]) {
    NSInteger blocks = [label isEqualToString:@"D"] ? dailyBlocks : weeklyBlocks;
    NSMutableAttributedString *line = [[NSMutableAttributedString alloc] init];
    [line appendAttributedString:[[NSAttributedString alloc] initWithString:[label stringByAppendingString:@" "]
      attributes:@{NSFontAttributeName: font}]];
    for (NSInteger i = 0; i < 10; i++) {
      NSString *ch = (i < blocks) ? @"█" : @"░";
      [line appendAttributedString:[[NSAttributedString alloc] initWithString:ch
        attributes:@{NSFontAttributeName: font}]];
    }
    if ([label isEqualToString:@"D"]) {
      [line appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
        attributes:@{NSFontAttributeName: font}]];
    }
    [attr appendAttributedString:line];
  }

  self.statusItem.button.attributedTitle = attr;
}

- (NSImage *)batteryImageWithDailyPercent:(double)dailyPercent weeklyPercent:(double)weeklyPercent {
  NSInteger dailyBlocks = (NSInteger)round(fmin(100.0, fmax(0.0, dailyPercent)) / 20.0);
  NSInteger weeklyBlocks = (NSInteger)round(fmin(100.0, fmax(0.0, weeklyPercent)) / 20.0);

  NSFont *font = [NSFont monospacedSystemFontOfSize:7.5 weight:NSFontWeightMedium];
  NSColor *solidColor = [NSColor labelColor];
  NSColor *emptyColor = [NSColor tertiaryLabelColor];
  NSDictionary *labelAttrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: solidColor};

  NSAttributedString *dLabel = [[NSAttributedString alloc] initWithString:@"D " attributes:labelAttrs];
  NSAttributedString *wLabel = [[NSAttributedString alloc] initWithString:@"W " attributes:labelAttrs];

  NSMutableAttributedString *dailyLine = [[NSMutableAttributedString alloc] initWithAttributedString:dLabel];
  NSMutableAttributedString *weeklyLine = [[NSMutableAttributedString alloc] initWithAttributedString:wLabel];

  for (NSInteger i = 0; i < 5; i++) {
    NSColor *c = (i < dailyBlocks) ? solidColor : emptyColor;
    NSAttributedString *ch = [[NSAttributedString alloc] initWithString:@"▌"
      attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: c}];
    [dailyLine appendAttributedString:ch];
  }
  for (NSInteger i = 0; i < 5; i++) {
    NSColor *c = (i < weeklyBlocks) ? solidColor : emptyColor;
    NSAttributedString *ch = [[NSAttributedString alloc] initWithString:@"▌"
      attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: c}];
    [weeklyLine appendAttributedString:ch];
  }

  CGSize lineSize = [dailyLine size];
  CGFloat w = lineSize.width + 4;
  CGFloat h = lineSize.height * 2 + 2;

  NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
  [image lockFocus];
  [dailyLine drawAtPoint:NSMakePoint(2, lineSize.height + 1)];
  [weeklyLine drawAtPoint:NSMakePoint(2, 1)];
  [image unlockFocus];
  image.template = NO;
  return image;
}

@end

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    AppDelegate *delegate = [[AppDelegate alloc] init];
    [app setDelegate:delegate];
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    [app run];
  }
  return 0;
}
