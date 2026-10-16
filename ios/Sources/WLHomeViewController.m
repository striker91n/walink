#import "WLHomeViewController.h"
#import "WLEngine.h"

#import <CoreImage/CoreImage.h>

@interface WLHomeViewController () <UITextFieldDelegate>

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIImageView *qrImageView;
@property (nonatomic, strong) UITextField *jidField;
@property (nonatomic, strong) UITextField *messageField;
@property (nonatomic, strong) UIButton *sendButton;
@property (nonatomic, strong) UITextView *logTextView;

@property (nonatomic, assign) NSInteger lastEventId;
@property (nonatomic, copy) NSString *connectionState;
@property (nonatomic, strong) NSDictionary *currentUser;

@end

@implementation WLHomeViewController

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.title = @"Walink";
    self.view.backgroundColor = [UIColor whiteColor];
    self.lastEventId = 0;
    self.connectionState = nil;

    [self setupViews];
    [self updateStatusLabel];

    // Surface a dead Node runtime instead of sitting at "Starting engine…" forever.
    __weak typeof(self) weakSelf = self;
    [WLEngine shared].startupFailureHandler = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (strongSelf.connectionState.length == 0) {
            strongSelf.statusLabel.text = @"Engine failed to start — check the log";
        }
        [strongSelf appendLog:@"[system] engine never became ready; the Node runtime may have failed to launch"];
    };

    // Start the engine (idempotent) and begin the long-poll loop.
    [[WLEngine shared] start];
    [self startPolling];

    // Dismiss keyboard when tapping outside the text fields.
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(dismissKeyboard)];
    [self.view addGestureRecognizer:tap];
}

#pragma mark - UI setup

- (void)setupViews
{
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.scrollView];

    self.contentView = [[UIView alloc] init];
    self.contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.contentView];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    [self.contentView addSubview:self.statusLabel];

    self.qrImageView = [[UIImageView alloc] init];
    self.qrImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.qrImageView.contentMode = UIViewContentModeScaleAspectFit;
    [self.contentView addSubview:self.qrImageView];

    self.jidField = [self textFieldWithPlaceholder:@"JID (e.g. 15551234567@s.whatsapp.net)"];
    [self.contentView addSubview:self.jidField];

    self.messageField = [self textFieldWithPlaceholder:@"Message"];
    [self.contentView addSubview:self.messageField];

    self.sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sendButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sendButton setTitle:@"Send" forState:UIControlStateNormal];
    self.sendButton.titleLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightSemibold];
    [self.sendButton addTarget:self
                        action:@selector(sendTapped:)
              forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:self.sendButton];

    self.logTextView = [[UITextView alloc] init];
    self.logTextView.translatesAutoresizingMaskIntoConstraints = NO;
    self.logTextView.editable = NO;
    self.logTextView.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.logTextView.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];
    self.logTextView.layer.borderColor = [UIColor lightGrayColor].CGColor;
    self.logTextView.layer.borderWidth = 0.5;
    self.logTextView.layer.cornerRadius = 6.0;
    [self.contentView addSubview:self.logTextView];

    [NSLayoutConstraint activateConstraints:@[
        // Scroll view fills the safe area.
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],

        // Content view fills the scroll view and matches its width.
        [self.contentView.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],
        [self.contentView.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor],
        [self.contentView.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor],
        [self.contentView.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor],
        [self.contentView.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor],

        // Status label.
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:20.0],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20.0],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20.0],

        // QR code image.
        [self.qrImageView.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:20.0],
        [self.qrImageView.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [self.qrImageView.widthAnchor constraintEqualToConstant:260.0],
        [self.qrImageView.heightAnchor constraintEqualToConstant:260.0],

        // JID field.
        [self.jidField.topAnchor constraintEqualToAnchor:self.qrImageView.bottomAnchor constant:20.0],
        [self.jidField.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20.0],
        [self.jidField.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20.0],
        [self.jidField.heightAnchor constraintEqualToConstant:44.0],

        // Message field.
        [self.messageField.topAnchor constraintEqualToAnchor:self.jidField.bottomAnchor constant:12.0],
        [self.messageField.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20.0],
        [self.messageField.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20.0],
        [self.messageField.heightAnchor constraintEqualToConstant:44.0],

        // Send button.
        [self.sendButton.topAnchor constraintEqualToAnchor:self.messageField.bottomAnchor constant:16.0],
        [self.sendButton.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [self.sendButton.widthAnchor constraintEqualToConstant:120.0],
        [self.sendButton.heightAnchor constraintEqualToConstant:44.0],

        // Log text view.
        [self.logTextView.topAnchor constraintEqualToAnchor:self.sendButton.bottomAnchor constant:20.0],
        [self.logTextView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20.0],
        [self.logTextView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20.0],
        [self.logTextView.heightAnchor constraintEqualToConstant:220.0],
        [self.logTextView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-20.0]
    ]];
}

- (UITextField *)textFieldWithPlaceholder:(NSString *)placeholder
{
    UITextField *field = [[UITextField alloc] init];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.placeholder = placeholder;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.delegate = self;
    return field;
}

#pragma mark - Actions

- (void)sendTapped:(UIButton *)sender
{
    NSString *jid = [self.jidField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *text = self.messageField.text;

    if (jid.length == 0 || text.length == 0) {
        [self appendLog:@"[system] enter a JID and message first"];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [[WLEngine shared] sendText:text
                        toJID:jid
                   completion:^(BOOL ok, NSString *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (ok) {
            [strongSelf appendLog:[NSString stringWithFormat:@"[sent to %@]: %@", jid, text]];
            strongSelf.messageField.text = @"";
        } else {
            [strongSelf appendLog:[NSString stringWithFormat:@"[send failed]: %@", error ?: @"unknown error"]];
        }
    }];
}

- (void)dismissKeyboard
{
    [self.view endEditing:YES];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - Polling

- (void)startPolling
{
    __weak typeof(self) weakSelf = self;
    [[WLEngine shared] pollEventsSince:self.lastEventId
                            completion:^(NSArray *events, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (error) {
            // Engine down or restarting: back off so we don't spin on a dead socket.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [strongSelf startPolling];
            });
            return;
        }

        if (events.count > 0) {
            [strongSelf processEvents:events];
        }

        // Immediately long-poll again.
        [strongSelf startPolling];
    }];
}

- (void)processEvents:(NSArray *)events
{
    for (NSDictionary *event in events) {
        NSNumber *eventId = event[@"id"];
        if (eventId && eventId.integerValue > self.lastEventId) {
            self.lastEventId = eventId.integerValue;
        }

        NSString *type = event[@"type"];
        if ([type isEqualToString:@"qr"]) {
            NSString *qrString = event[@"qr"];
            if (qrString.length > 0) {
                self.qrImageView.image = [self qrImageFromString:qrString size:CGSizeMake(260.0, 260.0)];
            }
        } else if ([type isEqualToString:@"connection"]) {
            // JSON null arrives as NSNull, and the engine sends `user: null` while
            // connecting/closing. Coerce both fields so later subscripting and
            // -isEqualToString: calls can never hit an NSNull.
            id stateValue = event[@"state"];
            self.connectionState = [stateValue isKindOfClass:[NSString class]] ? stateValue : nil;

            id userValue = event[@"user"];
            self.currentUser = [userValue isKindOfClass:[NSDictionary class]] ? userValue : nil;

            [self updateStatusLabel];

            // The engine sends `code` as a JSON number (a Baileys DisconnectReason),
            // so coerce it before touching any NSString API.
            id codeValue = event[@"code"];
            NSString *code = nil;
            if ([codeValue isKindOfClass:[NSNumber class]]) {
                code = [(NSNumber *)codeValue stringValue];
            } else if ([codeValue isKindOfClass:[NSString class]]) {
                code = codeValue;
            }
            if (code.length > 0) {
                [self appendLog:[NSString stringWithFormat:@"[connection] state=%@ code=%@",
                                 self.connectionState ?: @"?", code]];
            } else {
                [self appendLog:[NSString stringWithFormat:@"[connection] state=%@",
                                 self.connectionState ?: @"?"]];
            }
        } else if ([type isEqualToString:@"message"]) {
            NSDictionary *message = event[@"message"];
            NSString *senderName = message[@"pushName"] ?: message[@"jid"];
            NSString *text = message[@"text"] ?: @"";
            [self appendLog:[NSString stringWithFormat:@"%@: %@", senderName ?: @"unknown", text]];
        }
    }
}

#pragma mark - Status / QR / Log

- (void)updateStatusLabel
{
    NSString *userName = self.currentUser[@"name"] ?: self.currentUser[@"id"];

    if ([self.connectionState isEqualToString:@"open"]) {
        if (userName.length > 0) {
            self.statusLabel.text = [NSString stringWithFormat:@"Connected as %@", userName];
        } else {
            self.statusLabel.text = @"Connected";
        }
        self.qrImageView.image = nil;
    } else if ([self.connectionState isEqualToString:@"connecting"]) {
        self.statusLabel.text = @"Connecting…";
    } else if ([self.connectionState isEqualToString:@"close"]) {
        self.statusLabel.text = @"Disconnected";
    } else {
        self.statusLabel.text = @"Starting engine…";
    }
}

- (UIImage *)qrImageFromString:(NSString *)string size:(CGSize)size
{
    if (string.length == 0) return nil;

    NSData *data = [string dataUsingEncoding:NSISOLatin1StringEncoding];
    if (!data) return nil;

    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:data forKey:@"inputMessage"];
    [filter setValue:@"M" forKey:@"inputCorrectionLevel"];

    CIImage *outputImage = filter.outputImage;
    if (!outputImage) return nil;

    CGFloat scaleX = size.width / CGRectGetWidth(outputImage.extent);
    CGFloat scaleY = size.height / CGRectGetHeight(outputImage.extent);
    CIImage *scaledImage = [outputImage imageByApplyingTransform:CGAffineTransformMakeScale(scaleX, scaleY)];

    CIContext *context = [CIContext contextWithOptions:nil];
    CGImageRef cgImage = [context createCGImage:scaledImage fromRect:scaledImage.extent];
    if (!cgImage) return nil;

    UIImage *image = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);
    return image;
}

- (void)appendLog:(NSString *)line
{
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"HH:mm:ss";
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];

    NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", timestamp, line];

    dispatch_async(dispatch_get_main_queue(), ^{
        self.logTextView.text = [self.logTextView.text stringByAppendingString:entry];

        // Keep the most recent text visible.
        NSRange bottom = NSMakeRange(self.logTextView.text.length, 0);
        [self.logTextView scrollRangeToVisible:bottom];

        // Limit the log size so memory does not grow without bound.
        if (self.logTextView.text.length > 50000) {
            NSString *trimmed = [self.logTextView.text substringFromIndex:self.logTextView.text.length - 40000];
            self.logTextView.text = trimmed;
        }
    });
}

@end
