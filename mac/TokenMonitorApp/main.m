#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@interface AppDelegate : NSObject <NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler, NSMenuDelegate>
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSTimer *statusTimer;
@property(nonatomic, strong) WKWebView *claudeWebView;
@property(nonatomic, strong) NSWindow *claudeLoginWindow;
@property(nonatomic, assign) BOOL claudeWebViewPendingRead;
@property(nonatomic, assign) BOOL claudeAPIConnected;
@property(nonatomic, assign) BOOL codexLogConnected;
@property(nonatomic, assign) BOOL hasUsage;
@property(nonatomic, assign) double sessionPercent;
@property(nonatomic, assign) double weeklyPercent;
@property(nonatomic, copy) NSString *sessionResetText;
@property(nonatomic, copy) NSString *weeklyResetText;
@property(nonatomic, assign) BOOL codexHasUsage;
@property(nonatomic, assign) double codexSessionPercent;
@property(nonatomic, assign) double codexWeeklyPercent;
@property(nonatomic, copy) NSString *codexSessionResetText;
@property(nonatomic, copy) NSString *codexWeeklyResetText;
@end

@implementation AppDelegate

- (NSAttributedString *)statusTitleWithLabel:(NSString *)label connected:(BOOL)connected {
  NSColor *dotColor = connected ? [NSColor systemGreenColor] : [NSColor systemRedColor];
  CGFloat menuFontSize = [NSFont systemFontSize];
  NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:label
      attributes:@{NSFontAttributeName: [NSFont menuFontOfSize:0]}];
  [attr appendAttributedString:[[NSAttributedString alloc] initWithString:@"  ●"
      attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:menuFontSize * 0.6],
                   NSForegroundColorAttributeName: dotColor,
                   NSBaselineOffsetAttributeName: @(menuFontSize * 0.15)}]];
  return attr;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
  WKUserContentController *contentController = [[WKUserContentController alloc] init];
  [contentController addScriptMessageHandler:self name:@"claudeUsage"];
  [contentController addScriptMessageHandler:self name:@"claudeAppUsage"];
  [contentController addScriptMessageHandler:self name:@"closeWindow"];
  configuration.userContentController = contentController;

  // Headless data layer: the webView runs app.js (mirror state + status calc)
  // but is never shown in a window. The UI lives entirely in the status-bar menu.
  self.webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 327, 220) configuration:configuration];
  self.webView.navigationDelegate = self;

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
  [self updateStatusIconWithClaudeSession:0 claudeWeekly:0 codexSession:0 codexWeekly:0];
  self.statusItem.button.toolTip = @"Token Monitor";

  // Permanent menu → opens on both left- and right-click. Rebuilt on each open so
  // the Usage section always shows current values.
  NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Token Monitor"];
  menu.delegate = self;
  self.statusItem.menu = menu;

  self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                      target:self
                                                    selector:@selector(refreshStatusItem)
                                                    userInfo:nil
                                                     repeats:YES];
}

// Rebuild the menu contents right before it opens (NSMenuDelegate).
- (void)menuNeedsUpdate:(NSMenu *)menu {
  [menu removeAllItems];

  // ── Usage section ──
  NSMenuItem *usageHeader = [menu addItemWithTitle:@"Usage" action:nil keyEquivalent:@""];
  usageHeader.enabled = NO;
  if (self.hasUsage) {
    NSString *s = [NSString stringWithFormat:@"Claude 5h  %.0f%%   ·  %@", self.sessionPercent,
                   self.sessionResetText.length ? self.sessionResetText : @"Reset in 00:00"];
    NSString *w = [NSString stringWithFormat:@"Claude 7d  %.0f%%   ·  Reset %@", self.weeklyPercent,
                   self.weeklyResetText.length ? self.weeklyResetText : @"—"];
    [menu addItemWithTitle:s action:nil keyEquivalent:@""].enabled = NO;
    [menu addItemWithTitle:w action:nil keyEquivalent:@""].enabled = NO;
  }
  if (self.hasUsage && self.codexHasUsage) {
    [menu addItem:[NSMenuItem separatorItem]];
  }
  if (self.codexHasUsage) {
    NSString *s = [NSString stringWithFormat:@"Codex 5h   %.0f%%   ·  %@",
                   self.codexSessionPercent,
                   self.codexSessionResetText.length ? self.codexSessionResetText : @"Reset in 00:00"];
    NSString *w = [NSString stringWithFormat:@"Codex 7d   %.0f%%   ·  Reset %@",
                   self.codexWeeklyPercent,
                   self.codexWeeklyResetText.length ? self.codexWeeklyResetText : @"—"];
    [menu addItemWithTitle:s action:nil keyEquivalent:@""].enabled = NO;
    [menu addItemWithTitle:w action:nil keyEquivalent:@""].enabled = NO;
  }
  if (!self.hasUsage && !self.codexHasUsage) {
    [menu addItemWithTitle:@"กำลังโหลด…" action:nil keyEquivalent:@""].enabled = NO;
  }

  [menu addItem:[NSMenuItem separatorItem]];

  // ── Connection status (small colored dot) ──
  NSMenuItem *claudeApiItem = [menu addItemWithTitle:@"" action:@selector(setOAuthTokenFromMenu:) keyEquivalent:@""];
  claudeApiItem.attributedTitle = [self statusTitleWithLabel:@"Claude API" connected:self.claudeAPIConnected];

  NSMenuItem *codexLogItem = [menu addItemWithTitle:@"" action:@selector(refreshFromMenu:) keyEquivalent:@""];
  codexLogItem.attributedTitle = [self statusTitleWithLabel:@"Codex logs" connected:self.codexLogConnected];

  [menu addItemWithTitle:@"Refresh" action:@selector(refreshFromMenu:) keyEquivalent:@"r"];

  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItemWithTitle:[NSString stringWithFormat:@"About Token Monitor (v%@)", [self appVersion]]
                  action:@selector(showAboutFromMenu:) keyEquivalent:@""];
  [menu addItemWithTitle:@"Check for Updates…" action:@selector(checkForUpdatesFromMenu:) keyEquivalent:@""];
  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItemWithTitle:@"Quit" action:@selector(quitFromMenu:) keyEquivalent:@"q"];
}

- (void)refreshFromMenu:(id)sender {
  [self readClaudeDesktopUsage];
  [self readCodexUsageFromLogs];
}

- (NSString *)appVersion {
  return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
}

- (void)showAboutFromMenu:(id)sender {
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Token Monitor";
  alert.informativeText = [NSString stringWithFormat:@"เวอร์ชัน %@\n\nแสดงการใช้งาน Claude (session + weekly) บน menu bar แบบเรียลไทม์\n\nhttps://github.com/pippono9g-cloud/token-monitor", [self appVersion]];
  if (alert.icon == nil) alert.icon = [NSApp applicationIconImage];
  [alert addButtonWithTitle:@"OK"];
  [alert addButtonWithTitle:@"เปิดหน้า GitHub"];
  [NSApp activateIgnoringOtherApps:YES];
  if ([alert runModal] == NSAlertSecondButtonReturn) {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/pippono9g-cloud/token-monitor"]];
  }
}

- (void)checkForUpdatesFromMenu:(id)sender {
  NSURL *url = [NSURL URLWithString:@"https://api.github.com/repos/pippono9g-cloud/token-monitor/releases/latest"];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
  [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
  [req setValue:@"TokenMonitor" forHTTPHeaderField:@"User-Agent"];
  NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    NSString *latest = nil;
    if (data) {
      NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      if ([j isKindOfClass:[NSDictionary class]] && [j[@"tag_name"] isKindOfClass:[NSString class]]) {
        latest = [j[@"tag_name"] hasPrefix:@"v"] ? [j[@"tag_name"] substringFromIndex:1] : j[@"tag_name"];
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [self presentUpdateResult:latest];
    });
  }];
  [task resume];
}

// Compares dotted numeric versions. Returns YES if `latest` is newer than the running app.
- (BOOL)version:(NSString *)latest isNewerThan:(NSString *)current {
  return [latest compare:current options:NSNumericSearch] == NSOrderedDescending;
}

- (void)presentUpdateResult:(NSString *)latest {
  NSAlert *alert = [[NSAlert alloc] init];
  [NSApp activateIgnoringOtherApps:YES];
  if (latest.length == 0) {
    alert.messageText = @"เช็กอัปเดตไม่สำเร็จ";
    alert.informativeText = @"เชื่อมต่อ GitHub ไม่ได้ ลองใหม่อีกครั้งภายหลัง";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    return;
  }
  if ([self version:latest isNewerThan:[self appVersion]]) {
    alert.messageText = [NSString stringWithFormat:@"มีเวอร์ชันใหม่: v%@", latest];
    alert.informativeText = [NSString stringWithFormat:@"คุณกำลังใช้ v%@\nเปิดหน้าดาวน์โหลดเลยไหม?", [self appVersion]];
    [alert addButtonWithTitle:@"เปิดหน้าดาวน์โหลด"];
    [alert addButtonWithTitle:@"ภายหลัง"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
      [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/pippono9g-cloud/token-monitor/releases/latest"]];
    }
  } else {
    alert.messageText = @"เป็นเวอร์ชันล่าสุดแล้ว";
    alert.informativeText = [NSString stringWithFormat:@"v%@ เป็นเวอร์ชันใหม่ที่สุด", [self appVersion]];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
  }
}

- (void)quitFromMenu:(id)sender {
  [NSApp terminate:nil];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
  if (webView == self.claudeWebView) {
    [self handleClaudeWebViewDidLoad];
    return;
  }
  // Main webView finished loading — auto-fetch Claude and Codex usage.
  [self refreshStatusItem];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self readClaudeDesktopUsage];
    [self readCodexUsageFromLogs];
  });
  // Schedule auto-refresh every 3 minutes.
  [NSTimer scheduledTimerWithTimeInterval:3 * 60
                                   target:self
                                 selector:@selector(readCodexUsageFromLogs)
                                 userInfo:nil
                                  repeats:YES];
}

- (void)readCodexUsageFromLogs {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    NSString *script =
      @"import json, pathlib, time, datetime\n"
       "latest=None\n"
       "root=pathlib.Path.home()/'.codex'/'sessions'\n"
       "for p in root.rglob('*.jsonl'):\n"
       "    try:\n"
       "        with p.open(encoding='utf-8') as f:\n"
       "            for line in f:\n"
       "                if '\"type\":\"token_count\"' not in line:\n"
       "                    continue\n"
       "                obj=json.loads(line)\n"
       "                if obj.get('type')!='event_msg' or obj.get('payload',{}).get('type')!='token_count':\n"
       "                    continue\n"
       "                ts=obj.get('timestamp','')\n"
       "                if latest is None or ts > latest[0]:\n"
       "                    latest=(ts,obj)\n"
       "    except Exception:\n"
       "        pass\n"
       "if latest is None:\n"
       "    raise SystemExit('no Codex token_count events found')\n"
       "ts,obj=latest\n"
       "payload=obj['payload']\n"
       "rl=payload.get('rate_limits') or {}\n"
       "primary=rl.get('primary') or {}\n"
       "secondary=rl.get('secondary') or {}\n"
       "def weekday_time(epoch):\n"
       "    if not epoch: return ''\n"
       "    return datetime.datetime.fromtimestamp(epoch).strftime('%a %-I:%M %p')\n"
       "def reset_in(epoch):\n"
       "    if not epoch: return ''\n"
       "    seconds=max(0,int(epoch-time.time()))\n"
       "    h=seconds//3600\n"
       "    m=(seconds-h*3600)//60\n"
       "    return f'Reset in {h:02d}:{m:02d}'\n"
       "out={\n"
       "  'sessionPercent': float(primary.get('used_percent') or 0),\n"
       "  'weeklyPercent': float(secondary.get('used_percent') or 0),\n"
       "  'sessionReset': reset_in(primary.get('resets_at')),\n"
       "  'weeklyReset': weekday_time(secondary.get('resets_at')),\n"
       "  'planType': (rl.get('plan_type') or 'codex').title(),\n"
       "  'timestamp': ts,\n"
       "}\n"
       "print(json.dumps(out))\n";

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/python3";
    task.arguments = @[@"-c", script];
    NSPipe *outPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = [NSPipe pipe];
    @try { [task launch]; } @catch (NSException *e) {
      dispatch_async(dispatch_get_main_queue(), ^{
        self.codexLogConnected = NO;
        [self reportClaudeSyncError:@"Could not start Codex usage reader."];
      });
      return;
    }
    NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0 || data.length == 0) {
      dispatch_async(dispatch_get_main_queue(), ^{
        self.codexLogConnected = NO;
        [self reportClaudeSyncError:@"Could not read Codex usage logs."];
      });
      return;
    }
    NSDictionary *usage = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![usage isKindOfClass:[NSDictionary class]]) {
      dispatch_async(dispatch_get_main_queue(), ^{
        self.codexLogConnected = NO;
        [self reportClaudeSyncError:@"Could not parse Codex usage logs."];
      });
      return;
    }
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:usage options:0 error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      self.codexHasUsage = YES;
      self.codexSessionPercent = [usage[@"sessionPercent"] doubleValue];
      self.codexWeeklyPercent = [usage[@"weeklyPercent"] doubleValue];
      self.codexSessionResetText = usage[@"sessionReset"] ?: @"";
      self.codexWeeklyResetText = usage[@"weeklyReset"] ?: @"";
      self.codexLogConnected = YES;
      [self updateStatusIconWithClaudeSession:self.sessionPercent
                                 claudeWeekly:self.weeklyPercent
                                 codexSession:self.codexSessionPercent
                                  codexWeekly:self.codexWeeklyPercent];
      self.statusItem.button.toolTip = [NSString stringWithFormat:@"Claude 5h %.1f%% · 7d %.1f%%\nCodex 5h %.1f%% · 7d %.1f%%\n100%% = limit reached",
                                        self.sessionPercent, self.weeklyPercent,
                                        self.codexSessionPercent, self.codexWeeklyPercent];
    });
  });
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

// Reads the full credentials blob Claude Code keeps in the login keychain (includes claudeAiOauth).
- (NSDictionary *)keychainBlob {
  NSTask *task = [[NSTask alloc] init];
  task.launchPath = @"/usr/bin/security";
  task.arguments = @[@"find-generic-password", @"-s", @"Claude Code-credentials", @"-w"];
  NSPipe *outPipe = [NSPipe pipe];
  task.standardOutput = outPipe;
  task.standardError = [NSPipe pipe];
  @try { [task launch]; } @catch (NSException *e) { return nil; }
  NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
  [task waitUntilExit];
  if (task.terminationStatus != 0 || data.length == 0) return nil;
  NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [j isKindOfClass:[NSDictionary class]] ? j : nil;
}

// The claudeAiOauth sub-dict. Token carries the user:profile scope the usage endpoint needs.
- (NSDictionary *)claudeCredentials {
  NSDictionary *o = [self keychainBlob][@"claudeAiOauth"];
  return [o isKindOfClass:[NSDictionary class]] ? o : nil;
}

- (NSString *)oauthTokenFromKeychain {
  NSString *t = [self claudeCredentials][@"accessToken"];
  return [t isKindOfClass:[NSString class]] ? t : @"";
}

// Refreshes the access token via the OAuth refresh-token grant, then writes the rotated
// credentials back to the keychain so Claude Code keeps working with the same token.
// Returns the new access token, or @"" on failure. Background-only (blocks).
- (NSString *)refreshAccessTokenWritingBack {
  NSMutableDictionary *blob = [[self keychainBlob] mutableCopy];
  NSMutableDictionary *oauth = [blob[@"claudeAiOauth"] mutableCopy];
  NSString *rt = oauth[@"refreshToken"];
  if (![rt isKindOfClass:[NSString class]] || rt.length == 0) return @"";

  NSDictionary *payload = @{@"grant_type": @"refresh_token",
                            @"refresh_token": rt,
                            @"client_id": @"9d1c250a-e61b-44d9-88ed-5944d1962f5e"};
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://platform.claude.com/v1/oauth/token"]
                                                    cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                timeoutInterval:20];
  req.HTTPMethod = @"POST";
  [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [req setValue:@"claude-code/2.0.1 (external, cli)" forHTTPHeaderField:@"User-Agent"];
  req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

  __block NSData *respData = nil;
  __block NSInteger code = 0;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
    respData = d;
    code = [r isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)r).statusCode : 0;
    dispatch_semaphore_signal(sem);
  }] resume];
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)));

  if (code != 200 || respData.length == 0) return @"";
  NSDictionary *data = [NSJSONSerialization JSONObjectWithData:respData options:0 error:nil];
  NSString *at = data[@"access_token"];
  if (![at isKindOfClass:[NSString class]] || at.length == 0) return @"";

  oauth[@"accessToken"] = at;
  if ([data[@"refresh_token"] isKindOfClass:[NSString class]]) oauth[@"refreshToken"] = data[@"refresh_token"];
  double expiresIn = [data[@"expires_in"] doubleValue];
  if (expiresIn <= 0) expiresIn = 3600;
  oauth[@"expiresAt"] = @((long long)(([[NSDate date] timeIntervalSince1970] + expiresIn) * 1000.0));
  blob[@"claudeAiOauth"] = oauth;

  NSData *blobData = [NSJSONSerialization dataWithJSONObject:blob options:0 error:nil];
  NSString *blobStr = [[NSString alloc] initWithData:blobData encoding:NSUTF8StringEncoding];
  NSTask *write = [[NSTask alloc] init];
  write.launchPath = @"/usr/bin/security";
  write.arguments = @[@"add-generic-password", @"-U", @"-s", @"Claude Code-credentials",
                      @"-a", NSUserName(), @"-w", blobStr];
  write.standardOutput = [NSPipe pipe];
  write.standardError = [NSPipe pipe];
  @try { [write launch]; [write waitUntilExit]; } @catch (NSException *e) {}
  return at;
}

// Background-only: returns a fresh access token, refreshing (and writing back to the keychain)
// when the token is within 5 minutes of expiry. Falls back to a pasted token.
- (NSString *)freshOAuthToken {
  NSDictionary *creds = [self claudeCredentials];
  if (creds) {
    double expMs = [creds[@"expiresAt"] doubleValue];
    double nowMs = [[NSDate date] timeIntervalSince1970] * 1000.0;
    if (expMs > 0 && (expMs - nowMs) < 5 * 60 * 1000) {
      NSString *refreshed = [self refreshAccessTokenWritingBack];
      if (refreshed.length > 0) return refreshed;
    }
    NSString *t = creds[@"accessToken"];
    if ([t isKindOfClass:[NSString class]] && [t length] > 0) return t;
  }
  NSString *t = [[NSUserDefaults standardUserDefaults] stringForKey:@"claudeOAuthToken"];
  return [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

// Fast, main-thread-safe check used for the menu title (no refresh).
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
  // Resolve (and possibly refresh) the OAuth token off the main thread.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    NSString *token = [self freshOAuthToken];
    if (token.length > 0) {
      [self fetchUsageWithToken:token];
    } else {
      dispatch_async(dispatch_get_main_queue(), ^{ [self readClaudeDesktopWebUsage]; });
    }
  });
}

- (void)readClaudeDesktopWebUsage {
  self.claudeAPIConnected = NO;
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
    self.claudeLoginWindow.releasedWhenClosed = NO;
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
    NSString *countdown = [[text substringWithRange:[sessionResetMatch rangeAtIndex:1]] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    sessionReset = [self resetInStringFromCountdownText:countdown];
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
  return [NSString stringWithFormat:@"Reset in %02ld:%02ld", (long)h, (long)m];
}

- (NSString *)weekdayTimeStringFor:(NSDate *)date {
  if (!date) return @"";
  NSDateFormatter *f = [[NSDateFormatter alloc] init];
  f.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
  f.dateFormat = @"EEE h:mm a";
  return [f stringFromDate:date];
}

- (NSString *)weekdayTimeStringFromCountdownText:(NSString *)text {
  if (![text isKindOfClass:[NSString class]] || text.length == 0) return @"";
  NSRegularExpression *hoursRe = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)\\s*hr" options:0 error:nil];
  NSRegularExpression *minsRe = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)\\s*min" options:0 error:nil];
  NSTextCheckingResult *hoursMatch = [hoursRe firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
  NSTextCheckingResult *minsMatch = [minsRe firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
  NSInteger hours = 0;
  NSInteger minutes = 0;
  if (hoursMatch && hoursMatch.numberOfRanges > 1) {
    hours = [[text substringWithRange:[hoursMatch rangeAtIndex:1]] integerValue];
  }
  if (minsMatch && minsMatch.numberOfRanges > 1) {
    minutes = [[text substringWithRange:[minsMatch rangeAtIndex:1]] integerValue];
  }
  if (hours == 0 && minutes == 0) return @"";
  NSDate *date = [NSDate dateWithTimeIntervalSinceNow:(hours * 3600 + minutes * 60)];
  return [self weekdayTimeStringFor:date];
}

- (NSString *)resetInStringFromCountdownText:(NSString *)text {
  if (![text isKindOfClass:[NSString class]] || text.length == 0) return @"";
  if ([text hasPrefix:@"Reset in "]) return text;
  NSRegularExpression *clockRe = [NSRegularExpression regularExpressionWithPattern:@"^(\\d{1,2}):(\\d{2})$" options:0 error:nil];
  NSTextCheckingResult *clockMatch = [clockRe firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
  if (clockMatch && clockMatch.numberOfRanges > 2) {
    NSInteger hours = [[text substringWithRange:[clockMatch rangeAtIndex:1]] integerValue];
    NSInteger minutes = [[text substringWithRange:[clockMatch rangeAtIndex:2]] integerValue];
    return [NSString stringWithFormat:@"Reset in %02ld:%02ld", (long)hours, (long)minutes];
  }
  NSRegularExpression *hoursRe = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)\\s*hr" options:0 error:nil];
  NSRegularExpression *minsRe = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)\\s*min" options:0 error:nil];
  NSTextCheckingResult *hoursMatch = [hoursRe firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
  NSTextCheckingResult *minsMatch = [minsRe firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
  NSInteger hours = 0;
  NSInteger minutes = 0;
  if (hoursMatch && hoursMatch.numberOfRanges > 1) {
    hours = [[text substringWithRange:[hoursMatch rangeAtIndex:1]] integerValue];
  }
  if (minsMatch && minsMatch.numberOfRanges > 1) {
    minutes = [[text substringWithRange:[minsMatch rangeAtIndex:1]] integerValue];
  }
  if (hours == 0 && minutes == 0) return @"";
  return [NSString stringWithFormat:@"Reset in %02ld:%02ld", (long)hours, (long)minutes];
}

- (void)fetchUsageWithToken:(NSString *)token {
  [self fetchUsageWithToken:token allowRefresh:YES];
}

- (void)fetchUsageWithToken:(NSString *)token allowRefresh:(BOOL)allowRefresh {
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
      // 401/403 = token rejected. Try one refresh+retry before falling back to the web reader.
      if ((http.statusCode == 401 || http.statusCode == 403) && allowRefresh) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
          NSString *refreshed = [self refreshAccessTokenWritingBack];
          if (refreshed.length > 0) {
            [self fetchUsageWithToken:refreshed allowRefresh:NO];
          } else {
            dispatch_async(dispatch_get_main_queue(), ^{ [self readClaudeDesktopWebUsage]; });
          }
        });
        return;
      }
      dispatch_async(dispatch_get_main_queue(), ^{ [self readClaudeDesktopWebUsage]; });
      return;
    }
    if (http.statusCode == 429) {
      self.claudeAPIConnected = NO;
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
      self.claudeAPIConnected = YES;
      self.hasUsage = YES;
      self.sessionPercent = sessionPercent;
      self.weeklyPercent = weeklyPercent;
      self.sessionResetText = sessionReset.length ? sessionReset : self.sessionResetText;
      self.weeklyResetText = weeklyReset.length ? weeklyReset : self.weeklyResetText;
      [self updateStatusIconWithClaudeSession:self.sessionPercent
                                 claudeWeekly:self.weeklyPercent
                                 codexSession:self.codexSessionPercent
                                  codexWeekly:self.codexWeeklyPercent];
      [self.claudeLoginWindow orderOut:nil];
      NSString *script = [NSString stringWithFormat:@"window.applyClaudeAppUsage(%@);", json];
      [self.webView evaluateJavaScript:script completionHandler:^(id r, NSError *e) {
        if (!e) [self refreshStatusItem];
      }];
    });
  }];
  [task resume];
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
      self.claudeAPIConnected = NO;
      [self reportClaudeSyncError:[NSString stringWithFormat:@"Claude sync failed: %@", error.localizedDescription]];
      return;
    }

    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
      self.claudeAPIConnected = NO;
      NSString *message = [NSString stringWithFormat:@"Claude API returned %ld.", (long)httpResponse.statusCode];
      [self reportClaudeSyncError:message];
      return;
    }

    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (json.length == 0) {
      self.claudeAPIConnected = NO;
      [self reportClaudeSyncError:@"Claude API returned an empty response."];
      return;
    }

    NSString *script = [NSString stringWithFormat:@"window.importClaudeUsage(window.extractClaudeUsageEntries(%@), { message: 'Imported from Anthropic usage API.' });", json];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *scriptError) {
        if (scriptError) {
          self.claudeAPIConnected = NO;
          [self reportClaudeSyncError:[NSString stringWithFormat:@"Claude import failed: %@", scriptError.localizedDescription]];
        } else {
          self.claudeAPIConnected = YES;
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
      NSString *sessionResetDisplay = [self resetInStringFromCountdownText:dailyReset];
      if (sessionResetDisplay.length == 0 && [dailyReset hasPrefix:@"Reset in "]) sessionResetDisplay = dailyReset;
      if (sessionResetDisplay.length == 0 && self.sessionResetText.length > 0) sessionResetDisplay = self.sessionResetText;
      if (sessionResetDisplay.length == 0) sessionResetDisplay = @"Reset in 00:00";
      // Cache for the in-menu Usage section.
      self.hasUsage = YES;
      self.sessionPercent = dailyPercent;
      self.weeklyPercent = weeklyPercent;
      self.sessionResetText = sessionResetDisplay;
      self.weeklyResetText = weeklyReset;
      [self updateStatusIconWithClaudeSession:self.sessionPercent
                                 claudeWeekly:self.weeklyPercent
                                 codexSession:self.codexSessionPercent
                                  codexWeekly:self.codexWeeklyPercent];
      self.statusItem.button.toolTip = [NSString stringWithFormat:@"Claude 5h %.1f%% · %@\nClaude 7d %.1f%% · Reset %@\nCodex 5h %.1f%% · %@\nCodex 7d %.1f%% · Reset %@\n100%% = limit reached",
                                        self.sessionPercent,
                                        sessionResetDisplay.length ? sessionResetDisplay : @"Reset in 00:00",
                                        self.weeklyPercent,
                                        weeklyReset.length ? weeklyReset : @"—",
                                        self.codexSessionPercent,
                                        self.codexSessionResetText.length ? self.codexSessionResetText : @"Reset in 00:00",
                                        self.codexWeeklyPercent,
                                        self.codexWeeklyResetText.length ? self.codexWeeklyResetText : @"—"];
    });
  }];
}

- (void)updateStatusIconWithClaudeSession:(double)claudeSession
                             claudeWeekly:(double)claudeWeekly
                             codexSession:(double)codexSession
                              codexWeekly:(double)codexWeekly {
  NSInteger cs = (NSInteger)round(fmin(100.0, fmax(0.0, claudeSession)));
  NSInteger cw = (NSInteger)round(fmin(100.0, fmax(0.0, claudeWeekly)));
  NSInteger xs = (NSInteger)round(fmin(100.0, fmax(0.0, codexSession)));
  NSInteger xw = (NSInteger)round(fmin(100.0, fmax(0.0, codexWeekly)));

  // Layout: S | xx%C  xx%X
  //         W | xx%C  xx%X
  NSString *lblS = @"S", *lblW = @"W";
  NSString *cTop = [NSString stringWithFormat:@"%ld%%C", (long)cs];
  NSString *cBot = [NSString stringWithFormat:@"%ld%%C", (long)cw];
  NSString *xTop = [NSString stringWithFormat:@"%ld%%X", (long)xs];
  NSString *xBot = [NSString stringWithFormat:@"%ld%%X", (long)xw];

  NSFont *font = [NSFont monospacedDigitSystemFontOfSize:6.4 weight:NSFontWeightSemibold];
  NSDictionary *attrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: [NSColor blackColor]};

  NSSize lblSzS = [lblS sizeWithAttributes:attrs], lblSzW = [lblW sizeWithAttributes:attrs];
  NSSize cTopSz = [cTop sizeWithAttributes:attrs], cBotSz = [cBot sizeWithAttributes:attrs];
  NSSize xTopSz = [xTop sizeWithAttributes:attrs], xBotSz = [xBot sizeWithAttributes:attrs];

  CGFloat lblW_  = fmax(lblSzS.width, lblSzW.width);
  CGFloat cColW  = fmax(cTopSz.width, cBotSz.width);   // right-align %C values in this column
  CGFloat xColW  = fmax(xTopSz.width, xBotSz.width);   // right-align %X values in this column
  CGFloat lineH  = fmax(fmax(cTopSz.height, cBotSz.height), fmax(xTopSz.height, xBotSz.height));

  CGFloat padX = 1.0, padTop = 1.5, padBottom = 0.5;
  CGFloat gap = 2.0, divW = 1.0, colGap = 3.0;

  // X positions
  CGFloat divX    = padX + lblW_ + gap + divW / 2.0;
  CGFloat cStartX = padX + lblW_ + gap + divW + gap;   // left edge of C column
  CGFloat xStartX = cStartX + cColW + colGap;           // left edge of X column

  CGFloat imgW = ceil(xStartX + xColW + padX);
  CGFloat imgH = ceil(lineH * 2 + padTop + padBottom);

  NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(imgW, imgH)];
  [img lockFocus];
  CGFloat topY = imgH - padTop - lineH;
  CGFloat botY = padBottom;

  // S / W labels
  [lblS drawAtPoint:NSMakePoint(padX, topY) withAttributes:attrs];
  [lblW drawAtPoint:NSMakePoint(padX, botY) withAttributes:attrs];

  // %C column — right-aligned
  [cTop drawAtPoint:NSMakePoint(cStartX + cColW - cTopSz.width, topY) withAttributes:attrs];
  [cBot drawAtPoint:NSMakePoint(cStartX + cColW - cBotSz.width, botY) withAttributes:attrs];

  // %X column — left-aligned (already same-width due to monospaced digits)
  [xTop drawAtPoint:NSMakePoint(xStartX, topY) withAttributes:attrs];
  [xBot drawAtPoint:NSMakePoint(xStartX, botY) withAttributes:attrs];

  // Vertical divider spanning both rows
  CGFloat descent    = -font.descender;
  CGFloat capHeight  = font.capHeight;
  CGFloat divBottom  = botY + descent;
  CGFloat divTop     = topY + descent + capHeight + 1.0;
  NSBezierPath *div  = [NSBezierPath bezierPath];
  div.lineWidth = divW;
  [[NSColor blackColor] setStroke];
  [div moveToPoint:NSMakePoint(divX, divBottom)];
  [div lineToPoint:NSMakePoint(divX, divTop)];
  [div stroke];

  [img unlockFocus];
  img.template = YES;

  self.statusItem.button.image = img;
  self.statusItem.button.imagePosition = NSImageOnly;
  self.statusItem.button.title = @"";
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
  NSInteger s = (NSInteger)round(fmin(100.0, fmax(0.0, dailyPercent)));
  NSInteger w = (NSInteger)round(fmin(100.0, fmax(0.0, weeklyPercent)));
  NSString *lbl1 = @"S", *lbl2 = @"W";
  NSString *val1 = [NSString stringWithFormat:@"%ld%%", (long)s];
  NSString *val2 = [NSString stringWithFormat:@"%ld%%", (long)w];

  NSFont *font = [NSFont monospacedDigitSystemFontOfSize:6.5 weight:NSFontWeightSemibold];
  NSDictionary *attrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: [NSColor blackColor]};
  NSSize lblSz1 = [lbl1 sizeWithAttributes:attrs], lblSz2 = [lbl2 sizeWithAttributes:attrs];
  NSSize valSz1 = [val1 sizeWithAttributes:attrs], valSz2 = [val2 sizeWithAttributes:attrs];
  CGFloat lblW = fmax(lblSz1.width, lblSz2.width);
  CGFloat valW = fmax(valSz1.width, valSz2.width);
  CGFloat lineH = fmax(lblSz1.height, lblSz2.height);

  CGFloat padX = 1.0, padTop = 1.5, padBottom = 0.5, gap = 2.0, dividerW = 1.0;
  CGFloat imgW = ceil(padX + lblW + gap + dividerW + gap + valW + padX);
  CGFloat imgH = ceil(lineH * 2 + padTop + padBottom);

  NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(imgW, imgH)];
  [img lockFocus];

  CGFloat topY = imgH - padTop - lineH;     // baseline-origin of the top line
  CGFloat botY = padBottom;                  // baseline-origin of the bottom line
  CGFloat valX = padX + lblW + gap + dividerW + gap;

  // Labels (left column) and values (right column), each line aligned
  [lbl1 drawAtPoint:NSMakePoint(padX, topY) withAttributes:attrs];
  [lbl2 drawAtPoint:NSMakePoint(padX, botY) withAttributes:attrs];
  [val1 drawAtPoint:NSMakePoint(valX, topY) withAttributes:attrs];
  [val2 drawAtPoint:NSMakePoint(valX, botY) withAttributes:attrs];

  // One continuous vertical divider matching the glyph extents:
  // from the baseline of the bottom line up to the cap-top of the top line.
  CGFloat descent = -font.descender;          // distance from line-box bottom up to baseline
  CGFloat capHeight = font.capHeight;
  CGFloat dividerBottom = botY + descent;     // baseline of "W"/value row (digits sit here)
  CGFloat dividerTop = topY + descent + capHeight + 1.0;  // cap-top of "S"/value row (+ small nudge)
  CGFloat divX = padX + lblW + gap + dividerW / 2.0;
  NSBezierPath *divider = [NSBezierPath bezierPath];
  divider.lineWidth = dividerW;
  [[NSColor blackColor] setStroke];
  [divider moveToPoint:NSMakePoint(divX, dividerBottom)];
  [divider lineToPoint:NSMakePoint(divX, dividerTop)];
  [divider stroke];

  [img unlockFocus];
  img.template = YES;  // let the menu bar tint it (white in dark mode, black in light)

  self.statusItem.button.image = img;
  self.statusItem.button.imagePosition = NSImageOnly;
  self.statusItem.button.title = @"";
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
    // Menu-bar utility: live in the status bar only, not the Dock or Cmd-Tab.
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [app run];
  }
  return 0;
}
