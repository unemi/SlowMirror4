//
//  OSCReceiver.m
//  SlowMirror4
//
//  Created by Tatsuo Unemi on 2025/08/15.
//

#import "OSCReceiver.h"
#import "AppDelegate.h"
#import <sys/socket.h>
#import <sys/ioctl.h>
#import <arpa/inet.h>
#import <net/if.h>
#define OSC_PORT 5000
#define HTTP_PORT 8000
#define BUFFER_SIZE 8192

static void unix_error_msg(NSString *msg) {
	error_msg([NSString stringWithFormat:@"%@: %s.", msg, strerror(errno)], errno);
}
static NSString *address_string(in_addr_t addr) {
	union { UInt8 c[4]; UInt32 i; } u = { .i = addr }; 
	return [NSString stringWithFormat:@"%d.%d.%d.%d",u.c[0],u.c[1],u.c[2],u.c[3]];
}
static NSString *keyOSCPortNumber = @"OSCPortNumber", *keyOSCEnabled = @"OSCEnabled",
	*keyHTTPPortNumber = @"HTTPPortNumber", *keyHTTPEnabled = @"HTTPEnabled";

@interface OSCReceiver () {
	IBOutlet NSSwitch *enableSw;
	IBOutlet NSTextField *ipTxt, *bcTxt, *portTxt, *lastComTxt;
	NSRect portTxtFrame;
	int rcvSoc;
	in_addr_t myAddr, myBcAddr;
	in_port_t receiverPort;
	NSThread *rcvThread;

// for HTTP Server
	IBOutlet NSSwitch *httpSw;
	IBOutlet NSTextField *httpPortTxt, *urlTxt, *lastRequestTxt;
	IBOutlet NSButton *urlCopyBtn;
	NSRect httpPortTxtFrame;
	int httpSoc;
	in_addr_t clientAddr;
	in_port_t httpPort;
	NSThread *httpThread;
	CGFloat copyBtnY, copyBtnPadding;
//
	NSDateFormatter *logTimeFormat;
}
@end

@implementation OSCReceiver
- (void)showCommInfo {
	ipTxt.stringValue = address_string(myAddr);
	bcTxt.stringValue = address_string(myBcAddr);
}
- (void)closeSocketIfOpen {
	if (rcvSoc >= 0) { close(rcvSoc); rcvSoc = -1; }
	if (httpSoc >= 0) { close(httpSoc); httpSoc = -1; }
}
- (void)resetIPInfoIfNeeded {
	if (rcvSoc >= 0 || httpSoc >= 0) return;
	myAddr = 0;
	myBcAddr = -1;
	[self showCommInfo];
}
- (void)resetOSC {
	if (rcvSoc >= 0) { close(rcvSoc); rcvSoc = -1; }
	enableSw.state = NSControlStateValueOff;
	[self resetIPInfoIfNeeded];
}
- (void)resetHTTP {
	if (httpSoc >= 0) { close(httpSoc); httpSoc = -1; }
	httpSw.state = NSControlStateValueOff;
	[self resetIPInfoIfNeeded];
}
- (void)fixPortText:(NSTextField *)prtTxt origin:(NSPoint)origin {
	[prtTxt abortEditing];
	prtTxt.selectable = prtTxt.editable = NO;
	prtTxt.drawsBackground = NO;
	prtTxt.bordered = NO;
	[prtTxt sizeToFit];
	[prtTxt setFrameOrigin:origin];
}
- (void)unfixPortText:(NSTextField *)prtTxt frame:(NSRect)frame {
	prtTxt.editable = prtTxt.selectable = YES;
	prtTxt.drawsBackground = YES;
	prtTxt.bordered = YES;
	prtTxt.frame = frame;
}
//
- (BOOL)checkMyNetwork {
	if (rcvSoc >= 0 || httpSoc >= 0) return YES;
	int soc = socket(PF_INET, SOCK_DGRAM, IPPROTO_UDP);
	@try {
		myAddr = 0;
		if (soc < 0) @throw @"UDP socket";
		struct ifreq ifReq = { "en0" };
		for (int i = 0; i < 8; i ++) {
			ifReq.ifr_name[2] = '0' + i;
			if (ioctl(soc, SIOCGIFADDR, &ifReq) < 0) continue;
			myAddr = ((struct sockaddr_in *)&ifReq.ifr_ifru.ifru_addr)->sin_addr.s_addr;
			break;
		}
		if (myAddr != 0) {
			if (ioctl(soc, SIOCGIFNETMASK, &ifReq) < 0) @throw @"Get my netmask";
			in_addr_t mask = ((struct sockaddr_in *)&ifReq.ifr_ifru.ifru_addr)
				->sin_addr.s_addr;
			myBcAddr = myAddr | ~ mask;
		} else {
			myAddr = inet_addr("127.0.0.1");
			myBcAddr = inet_addr("127.255.255.255");
		}
		close(soc);
		[self showCommInfo];
	} @catch (NSString *msg) {
		myBcAddr = -1;
		[self showCommInfo];
		if (soc >= 0) close(soc);
		unix_error_msg(msg);
		return NO;
	}
	return YES;
}
//
- (void)receiverThread:(id)userInfo {
	struct sockaddr name;
	char buf[BUFSIZ];
	NSThread *myThread = rcvThread = NSThread.currentThread;
	while (!myThread.cancelled) {
		socklen_t len = sizeof(name);
		ssize_t n = recvfrom(rcvSoc, buf, BUFSIZ, 0, &name, &len);
		if (n == 0) continue;
		else if (n < 0) break;
		NSString *logStr = [NSString stringWithFormat:@"%@ %@ %s",
			[logTimeFormat stringFromDate:NSDate.date],
			address_string(((struct sockaddr_in *)&name)->sin_addr.s_addr), buf];;
		NSData *data = [NSData dataWithBytes:buf length:n];
		in_main_thread(^{
			AppDelegate *dlgt = (AppDelegate *)NSApp.delegate;
			const char *bytes = data.bytes;
			if (strcmp(bytes, "/next") == 0) [dlgt goNext:nil];
			else if (strcmp(bytes, "/back") == 0) [dlgt goBack:nil];
			else if (strcmp(bytes, "/restart") == 0) [dlgt restart:nil];
			else if (strcmp(bytes, "/cameraOn") == 0) [dlgt cameraOn];
			else if (strcmp(bytes, "/cameraOff") == 0) [dlgt cameraOff];
			self->lastComTxt.stringValue = logStr;
		});
	}
	in_main_thread(^{ [self resetOSC]; });
}
#define N_PORTS_TO_TRY 100
- (BOOL)startReceiverWithPort:(in_port_t)rcvPort {
	if (![self checkMyNetwork]) return NO;
	int newSoc = -1;
	in_port_t maxPort = rcvPort + N_PORTS_TO_TRY - 1;
	if (maxPort < rcvPort) maxPort = 65535;
	@try {
		if (rcvThread != nil && rcvThread.executing) {
			if (receiverPort >= rcvPort && receiverPort < maxPort) return YES;
			[rcvThread cancel];
			if (close(rcvSoc) < 0) @throw @"Couldn't close receiver's socket";
		}
		newSoc = socket(PF_INET, SOCK_DGRAM, IPPROTO_UDP);
		if (newSoc < 0) @throw @"Couldn't make receiver's socket";
		struct sockaddr_in name = {sizeof(name), AF_INET, 0, {INADDR_ANY}};
		for (in_port_t port = rcvPort; port <= maxPort; port ++) {
			name.sin_port = EndianU16_NtoB(port);
			if (bind(newSoc, (struct sockaddr *)&name, sizeof(name)) == noErr)
				{ receiverPort = port; @throw @YES; }
		} @throw [NSString stringWithFormat:
			@"Port %d - %d seems busy.", rcvPort, maxPort];
	} @catch (NSString *msg) {
		if (newSoc >= 0) close(newSoc);
		rcvSoc = -1;
		unix_error_msg(msg);
		return NO;
	} @catch (NSNumber *num) {
		rcvSoc = newSoc;
		[NSThread detachNewThreadSelector:
			@selector(receiverThread:) toTarget:self withObject:nil];
		return YES;
	}
	return NO;
}
- (BOOL)stopReceiver {
	if (rcvSoc >= 0 && close(rcvSoc) != noErr) {
		unix_error_msg(@"Couldn't close receiver's socket");
		return NO;
	} else rcvSoc = -1;
	if (rcvThread != nil && rcvThread.executing) {
		[rcvThread cancel];
		rcvThread = nil;
	}
	[self unfixPortText:portTxt frame:portTxtFrame];
	return YES;
}
//
static void reply_http(int desc, NSString *resultCodeStr, NSString *resStr, NSString *tpStr) {
	static NSString *headerFormat = @"HTTP/1.1 %@\n"
		@"Date: %@\nServer: %@\nContent-Length: %ld\n"
		@"Content-Type: text/%@\nConnection: keep-alive\n\n";
	static NSDateFormatter *dateFormat = nil;
	if (dateFormat == nil) {
		dateFormat = NSDateFormatter.new;
		dateFormat.locale = [NSLocale.alloc initWithLocaleIdentifier:@"en_GB"];
		dateFormat.timeZone = [NSTimeZone timeZoneWithName:@"GMT"];
		dateFormat.dateFormat = @"E, d MMM Y HH:mm:ss zzz"; //Mon, 31 Aug 2020 05:08:47 GMT
	}
	NSString *response = [NSString stringWithFormat:headerFormat,
		resultCodeStr, [dateFormat stringFromDate:NSDate.date],
		NSBundle.mainBundle.bundleIdentifier,
		resStr.length, tpStr];
	ssize_t result = send(desc, response.UTF8String, response.length, 0);
	result = send(desc, resStr.UTF8String, resStr.length, 0);
}
- (void)httpServerThread:(NSArray<NSNumber *> *)userInfo {
	static NSString *mainContent = nil;
	int desc = userInfo[0].intValue;
	uint32 ipaddr = userInfo[1].intValue;
	char *buf = malloc(BUFFER_SIZE);
	NSString *clientIPStr = address_string(ipaddr);
	NSThread.currentThread.name = [NSString stringWithFormat:
		@"HTTP interaction with %@", clientIPStr];
	if (mainContent == nil) {
		NSError *error;
		mainContent = [NSString stringWithContentsOfURL:
			[NSBundle.mainBundle URLForResource:@"Controller" withExtension:@"html"]
			encoding:NSUTF8StringEncoding error:&error];
		if (mainContent == nil) err_msg(error, YES);
	}
	@try { for (;;) @autoreleasepool {
		long len = recv(desc, buf, BUFFER_SIZE - 1, 0);
		if (len <= 0 || len >= BUFFER_SIZE) @throw @1;
		buf[len] = '\0';
//		printf("%s\n%ld bytes", buf, len);
		if (strncmp(buf, "GET /", 5) != 0) {
			in_main_thread(^{ reply_http(desc, @"405 Method Not Allowed",
				@"Accepts only \"GET\" method.", @"text"); });
			continue;
		}
		char com[32];
		for (NSInteger i = 0; i < 31; i ++) {
			char c = buf[i + 4];
			if (c <= ' ' || c >= '\177') { com[i] = '\0'; break; }
			com[i] = c;
			if (i >= 30) com[31] = '\0';
		}
		NSString *logStr = [NSString stringWithFormat:@"%@ %@ %s",
			[logTimeFormat stringFromDate:NSDate.date], clientIPStr, com];
		if (com[1] == '\0') in_main_thread(^{
			reply_http(desc, @"200 OK", mainContent, @"html");
			self->lastRequestTxt.stringValue = logStr;
		});
		else {
			SEL action  = 
				(strcmp(com, "/toggleCamera") == 0)? @selector(toggleCamera:) :
				(strcmp(com, "/restart") == 0)? @selector(restart:) :
				(strcmp(com, "/back") == 0)? @selector(goBack:) :
				(strcmp(com, "/next") == 0)? @selector(goNext:) : nil;
			if (action == nil && strcmp(com, "/state") != 0) {
				NSString *resStr = [NSString stringWithFormat:
					@"Command \"%s\" not found.", com + 1];
				in_main_thread(^{ reply_http(desc, @"404 Not Found", resStr, @"text"); });
			} else in_main_thread(^{
				AppDelegate *dlg = (AppDelegate *)NSApp.delegate;
				if (action) [dlg performSelector:action withObject:nil];
				reply_http(desc, @"200 OK", [NSString stringWithFormat:
					@"{\"camera\":%d,\"button\":%d,\"state\":%d}",
					dlg.cameraState, dlg.buttonState, dlg.currentState], @"json");
				self->lastRequestTxt.stringValue = logStr;
			});
		}
	}} @catch (id _) { }
	free(buf);
}
- (void)connectionThread:(id)userInfo {
	uint32 addrlen;
	int desc = -1;
	NSThread.currentThread.name = @"HTTP connection";
	NSThread *myThread = httpThread = NSThread.currentThread;
	while (!myThread.cancelled) @autoreleasepool {
		struct sockaddr_in name = {sizeof(name), AF_INET, EndianU16_NtoB(httpPort), {INADDR_ANY}};
		addrlen = sizeof(name);
		desc = accept(httpSoc, (struct sockaddr *)&name, &addrlen);
		if (desc < 0) break;
		[NSThread detachNewThreadSelector:
			@selector(httpServerThread:) toTarget:self withObject:
			@[@(desc), @(name.sin_addr.s_addr)]];
	}
	in_main_thread(^{ [self resetHTTP]; });
}
- (BOOL)startHTTPServerWithPort:(in_port_t)srvPort {
	if (![self checkMyNetwork]) return NO;
	int newSoc = -1;
	in_port_t maxPort = srvPort + N_PORTS_TO_TRY - 1;
	if (maxPort < srvPort) maxPort = 65535;
	@try {
		if (httpThread != nil && httpThread.executing) {
			if (httpPort >= srvPort && httpPort < maxPort) return YES;
			[httpThread cancel];
			if (close(httpSoc) < 0) @throw @"Couldn't close receiver's socket";
		}
		newSoc = socket(PF_INET, SOCK_STREAM, IPPROTO_TCP);
		if (newSoc < 0) @throw @"Couldn't make HTTP server's socket";
		struct sockaddr_in name = {sizeof(name), AF_INET, 0, {INADDR_ANY}};
		for (in_port_t port = srvPort; port <= maxPort; port ++) {
			name.sin_port = EndianU16_NtoB(port);
			if (bind(newSoc, (struct sockaddr *)&name, sizeof(name)) == noErr) {
				if (listen(newSoc, 1) != noErr) @throw @"TCP listen";
				httpPort = port;
				@throw @YES;
			}
		} @throw [NSString stringWithFormat:
			@"Port %d - %d seems busy.", srvPort, maxPort];
	} @catch (NSString *msg) {
		if (newSoc >= 0) close(newSoc);
		unix_error_msg(msg); return NO;
	} @catch (NSNumber *num) {
		httpSoc = newSoc;
		[NSThread detachNewThreadSelector:
			@selector(connectionThread:) toTarget:self withObject:nil];
		return YES;
	}
	return NO;
}
- (BOOL)stopHTTPServer {
	if (httpSoc >= 0 && close(httpSoc) != noErr) {
		unix_error_msg(@"Couldn't close HTTP server's socket");
		return NO;
	} else httpSoc = -1;
	httpThread = nil;
	[self unfixPortText:httpPortTxt frame:httpPortTxtFrame];
	urlTxt.stringValue = @"---";
	urlCopyBtn.hidden = YES;
	return YES;
}
//
- (void)setupConnectionInfo {
	in_port_t portNum = portTxt.integerValue;
	if ([self startReceiverWithPort:portNum]) {
		[self fixPortText:portTxt origin:
			(NSPoint){portTxtFrame.origin.x, lastComTxt.frame.origin.y}];
		[UserDefaults setInteger:portNum forKey:keyOSCPortNumber];
	} else enableSw.state = NSControlStateValueOff;
}
- (void)setupHTTPServerInfo {
	in_port_t portNum = httpPortTxt.integerValue;
	if ([self startHTTPServerWithPort:portNum]) {
		[self fixPortText:httpPortTxt origin:
			(NSPoint){httpPortTxtFrame.origin.x, lastRequestTxt.frame.origin.y}];
		[UserDefaults setInteger:portNum forKey:keyHTTPPortNumber];
		urlTxt.stringValue = [NSString stringWithFormat:
			@"http://%@:%d", address_string(myAddr), portNum];
		[urlTxt sizeToFit];
		[urlCopyBtn setFrameOrigin:
			(NSPoint){NSMaxX(urlTxt.frame) + copyBtnPadding, copyBtnY}];
		urlCopyBtn.hidden = NO;
	} else httpSw.state = NSControlStateValueOff;
}
static BOOL default_bool(NSString *key) {
	NSNumber *num = [UserDefaults objectForKey:key];
	return num? num.boolValue : YES;
}
- (void)awakeFromNib {
	rcvSoc = httpSoc = -1;
	NSNumber *num = [UserDefaults objectForKey:keyOSCPortNumber];
	portTxt.integerValue = num? num.integerValue : OSC_PORT;
	portTxtFrame = portTxt.frame;
	num = [UserDefaults objectForKey:keyHTTPPortNumber];
	httpPortTxt.integerValue = num? num.integerValue : HTTP_PORT;
	httpPortTxtFrame = httpPortTxt.frame;
	enableSw.state = default_bool(keyOSCEnabled);
	httpSw.state = default_bool(keyHTTPEnabled);
	lastComTxt.stringValue = lastRequestTxt.stringValue =
		urlTxt.stringValue = @"---";
	NSPoint btnOrigin = urlCopyBtn.frame.origin;
	copyBtnY = btnOrigin.y;
	copyBtnPadding = btnOrigin.x - NSMaxX(urlTxt.frame);
	urlCopyBtn.hidden = YES;
	logTimeFormat = NSDateFormatter.new;
	logTimeFormat.dateFormat = @"HH':'mm':'ss'.'SS";
	if ([self checkMyNetwork]) {
		if (enableSw.state) [self setupConnectionInfo];
		if (httpSw.state) [self setupHTTPServerInfo];
	} else enableSw.state = httpSw.state = NSControlStateValueOff;
}
- (IBAction)switchComm:(id)sender {
	if (enableSw.state) [self setupConnectionInfo];
	else [self stopReceiver];
	[UserDefaults setBool:enableSw.state forKey:keyOSCEnabled];
}
- (IBAction)switchHTTP:(id)sender {
	if (httpSw.state) [self setupHTTPServerInfo];
	else [self stopHTTPServer];
	[UserDefaults setBool:httpSw.state forKey:keyHTTPEnabled];
}
- (IBAction)copyURL:(id)sender {
	NSPasteboard *pb = NSPasteboard.generalPasteboard;
	[pb clearContents];
	[pb setString:urlTxt.stringValue forType:NSPasteboardTypeString];
}
@end
