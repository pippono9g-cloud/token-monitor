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
  NSString *tokenTitle = [self oauthToken].length > 0 ? @"API: เรียลไทม์ ✓ (เชื่อม Claude Code)" : @"ตั้งค่า API เรียลไทม์…";
  [menu addItemWithTitle:tokenTitle action:@selector(setOAuthTokenFromMenu:) keyEquivalent:@""];
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
  // Main webView finished loading — auto-fetch Claude usage
  [self refreshStatusItem];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self readClaudeDesktopUsage];
  });
  // Schedule auto-refresh every 5 minutes
  [NSTimer scheduledTimerWithTimeInterval:5 * 60
                                   target:self
                                 selector:@selector(readClaudeDesktopUsage)
                                 userInfo:nil
                                  repeats:YES];
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

// Reads the live OAuth access token Claude Code keeps fresh in the login keychain.
// This token carries the user:profile scope the usage endpoint requires (unlike setup-token).
- (NSString *)oauthTokenFromKeychain {
  NSTask *task = [[NSTask alloc] init];
  task.launchPath = @"/usr/bin/security";
  task.arguments = @[@"find-generic-password", @"-s", @"Claude Code-credentials", @"-w"];
  NSPipe *outPipe = [NSPipe pipe];
  task.standardOutput = outPipe;
  task.standardError = [NSPipe pipe];
  @try { [task launch]; } @catch (NSException *e) { return @""; }
  NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
  [task waitUntilExit];
  if (task.terminationStatus != 0 || data.length == 0) return @"";
  NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![j isKindOfClass:[NSDictionary class]]) return @"";
  NSDictionary *o = j[@"claudeAiOauth"];
  if (![o isKindOfClass:[NSDictionary class]]) return @"";
  NSString *t = o[@"accessToken"];
  return [t isKindOfClass:[NSString class]] ? t : @"";
}

- (NSString *)oauthToken {
  NSString *kc = [self oauthTokenFromKeychain];
  if (kc.length > 0) return kc;
  NSString *t = [[NSUserDefaults standardUserDefaults] stringForKey:@"claudeOAuthToken"];
  return [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

- (void)setOAuthTokenFromMenu:(id)sender {
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"ตั้งค่า Claude API เรียลไทม์";
  alert.informativeText = @"แนะนำ: ติดตั้ง Claude Code แล้วรัน  claude auth login  ใน Terminal\nแอปจะอ่าน token สดจาก keychain ให้เองอัตโนมัติ (auto-refresh ไม่หมดอายุ)\n\nหรือถ้าต้องการใส่ token เอง ให้รัน  claude setup-token  แล้ววางด้านล่าง\n(หมายเหตุ: setup-token อาจขาด scope user:profile ทำให้ดู usage ไม่ได้)\n\nเว้นว่าง = ใช้วิธีอ่านจากหน้าเว็บ";
  NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 380, 24)];
  field.placeholderString = @"sk-ant-oat01-…";
  field.stringValue = [self oauthToken];
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"บันทึก"];
  [alert addButtonWithTitle:@"ยกเลิก"];
  [NSApp activateIgnoringOtherApps:YES];
  if ([alert runModal] == NSAlertFirstButtonReturn) {
    NSString *t = [field.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length > 0) {
      [[NSUserDefaults standardUserDefaults] setObject:t forKey:@"claudeOAuthToken"];
    } else {
      [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"claudeOAuthToken"];
    }
    [self readClaudeDesktopUsage];
  }
}

- (void)readClaudeDesktopUsage {
  if ([self fetchUsageViaOAuthToken]) return;
  [self readClaudeDesktopWebUsage];
}

- (void)readClaudeDesktopWebUsage {
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
  NSString *sessionReset = @"";

  // "Resets in 3 hr 36 min" or "Resets in 45 min" or "Resets in 2 hr"
  NSRegularExpression *sessionResetRegex = [NSRegularExpression regularExpressionWithPattern:@"Resets in (\\d+(?:\\s+hr(?:\\s+\\d+\\s+min)?)?(?:\\s*\\d+\\s+min)?)" options:0 error:nil];
  NSTextCheckingResult *sessionResetMatch = [sessionResetRegex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
  if (sessionResetMatch && sessionResetMatch.numberOfRanges > 1) {
    sessionReset = [[text substringWithRange:[sessionResetMatch rangeAtIndex:1]] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  }

  // "Resets Fri 12:59 AM"
  NSRegularExpression *resetRegex = [NSRegularExpression regularExpressionWithPattern:@"Resets\\s+([A-Za-z]{3}\\s+\\d{1,2}:\\d{2}\\s+[AP]M)" options:0 error:nil];
  NSTextCheckingResult *resetMatch = [resetRegex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
  if (resetMatch && resetMatch.numberOfRanges > 1) {
    weeklyReset = [text substringWithRange:[resetMatch rangeAtIndex:1]];
  }

  return @{@"sessionPercent": @(sessionPercent), @"weeklyPercent": @(weeklyPercent),
           @"weeklyReset": weeklyReset, @"sessionReset": sessionReset};
}


- (NSDate *)dateFromISOString:(id)iso {
  if (![iso isKindOfClass:[NSString class]] || [iso length] == 0) return nil;
  NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\.\\d+" options:0 error:nil];
  NSString *clean = [re stringByReplacingMatchesInString:iso options:0 range:NSMakeRange(0, [iso length]) withTemplate:@""];
  NSISO8601DateFormatter *f = [[NSISO8601DateFormatter alloc] init];
  return [f dateFromString:clean];
}

- (NSString *)countdownStringTo:(NSDate *)date {
  if (!date) return @"";
  NSTimeInterval s = [date timeIntervalSinceNow];
  if (s < 0) s = 0;
  NSInteger h = (NSInteger)(s / 3600);
  NSInteger m = (NSInteger)((s - h * 3600) / 60);
  if (h > 0) return [NSString stringWithFormat:@"%ld hr %ld min", (long)h, (long)m];
  return [NSString stringWithFormat:@"%ld min", (long)m];
}

- (NSString *)weekdayTimeStringFor:(NSDate *)date {
  if (!date) return @"";
  NSDateFormatter *f = [[NSDateFormatter alloc] init];
  f.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
  f.dateFormat = @"EEE h:mm a";
  return [f stringFromDate:date];
}

// Returns YES if an OAuth token is configured (and this path will handle the read).
- (BOOL)fetchUsageViaOAuthToken {
  NSString *token = [self oauthToken];
  if (token.length == 0) return NO;

  NSURL *url = [NSURL URLWithString:@"https://api.anthropic.com/api/oauth/usage"];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
  req.HTTPMethod = @"GET";
  [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
  [req setValue:@"oauth-2025-04-20" forHTTPHeaderField:@"anthropic-beta"];
  [req setValue:@"claude-code/2.0.1 (external, cli)" forHTTPHeaderField:@"User-Agent"];
  [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

  NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    if (error || http.statusCode == 401 || http.statusCode == 403) {
      // Token missing/expired — tell the user and fall back to the web reader.
      if (http.statusCode == 401 || http.statusCode == 403) {
        [self reportClaudeSyncError:@"API token หมดอายุหรือไม่ถูกต้อง รันใหม่: claude setup-token แล้วตั้งค่าใหม่ในเมนู"];
      }
      dispatch_async(dispatch_get_main_queue(), ^{ [self readClaudeDesktopWebUsage]; });
      return;
    }
    if (http.statusCode == 429) {
      [self reportClaudeSyncError:@"API ถูก rate-limit ชั่วคราว จะลองใหม่รอบถัดไป"];
      return;
    }
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:(data ?: [NSData data]) options:0 error:nil];
    if (![j isKindOfClass:[NSDictionary class]]) {
      dispatch_async(dispatch_get_main_queue(), ^{ [self readClaudeDesktopWebUsage]; });
      return;
    }

    NSDictionary *five = [j[@"five_hour"] isKindOfClass:[NSDictionary class]] ? j[@"five_hour"] : nil;
    NSDictionary *seven = [j[@"seven_day"] isKindOfClass:[NSDictionary class]] ? j[@"seven_day"] : nil;
    double sessionPercent = [five[@"utilization"] doubleValue];
    double weeklyPercent = [seven[@"utilization"] doubleValue];
    NSString *sessionReset = [self countdownStringTo:[self dateFromISOString:five[@"resets_at"]]];
    NSString *weeklyReset = [self weekdayTimeStringFor:[self dateFromISOString:seven[@"resets_at"]]];

    NSDictionary *usage = @{@"sessionPercent": @(sessionPercent),
                            @"weeklyPercent": @(weeklyPercent),
                            @"weeklyReset": weeklyReset.length ? weeklyReset : @"",
                            @"sessionReset": sessionReset.length ? sessionReset : @""};
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:usage options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self.claudeLoginWindow orderOut:nil];
      NSString *script = [NSString stringWithFormat:@"window.applyClaudeAppUsage(%@);", json];
      [self.webView evaluateJavaScript:script completionHandler:^(id r, NSError *e) {
        if (!e) [self refreshStatusItem];
      }];
    });
  }];
  [task resume];
  return YES;
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
      NSString *sessionResetDisplay = (dailyReset.length > 0 && [dailyReset rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location != NSNotFound && ![dailyReset containsString:@"/"]) ? [@"in " stringByAppendingString:dailyReset] : dailyReset;
      self.statusItem.button.toolTip = [NSString stringWithFormat:@"Session %.1f%% · resets %@\nWeekly %.1f%% · resets %@",
                                        dailyPercent,
                                        sessionResetDisplay,
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

  for (NSString *label in @[@"S", @"W"]) {
    NSInteger blocks = [label isEqualToString:@"S"] ? dailyBlocks : weeklyBlocks;
    NSMutableAttributedString *line = [[NSMutableAttributedString alloc] init];
    [line appendAttributedString:[[NSAttributedString alloc] initWithString:[label stringByAppendingString:@" "]
      attributes:@{NSFontAttributeName: font}]];
    for (NSInteger i = 0; i < 10; i++) {
      NSString *ch = (i < blocks) ? @"█" : @"░";
      [line appendAttributedString:[[NSAttributedString alloc] initWithString:ch
        attributes:@{NSFontAttributeName: font}]];
    }
    if ([label isEqualToString:@"S"]) {
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

  NSAttributedString *dLabel = [[NSAttributedString alloc] initWithString:@"S " attributes:labelAttrs];
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
