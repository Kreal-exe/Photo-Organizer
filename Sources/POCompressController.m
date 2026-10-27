#import "POCompressController.h"
#import "POStrings.h"

static NSString *const POCompressVideoHeightKey = @"compressVideoHeight";
static NSString *const POCompressVideoQualityKey = @"compressVideoQuality";

@implementation POCompressController {
    NSArray<POPhotoItem *> *_raws, *_allVideos;
    NSInteger _typicalMegapixels, _typicalCount, _rawMegapixels;
    double _typicalBytesPerMegapixel;
    NSMutableArray<NSNumber *> *_sizes;
    NSButton *_photosCheckbox, *_videosCheckbox, *_confirmButton;
    NSPopUpButton *_sizePopup, *_heightPopup, *_qualityPopup;
    NSTextField *_photoEstimate, *_videoEstimate, *_totalLabel;
    // What the trial compression found: bytes per photo at each size tried.
    NSMutableDictionary<NSNumber *, NSNumber *> *_sampled;
    NSMapTable<POPhotoItem *, POVideoInfo *> *_probed;
    NSUInteger _probeDone;
    BOOL _probing, _closed;
}

- (instancetype)initWithItems:(NSArray<POPhotoItem *> *)items library:(NSArray<POPhotoItem *> *)library {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _raws = [items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(POPhotoItem *item, NSDictionary *bindings) {
            return POIsRawItem(item) && !item.isCloudOnly;
        }]];
        _allVideos = [items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(POPhotoItem *item, NSDictionary *bindings) {
            return item.isVideo && !item.isCloudOnly;
        }]];
        POTypicalPhoto(library, &_typicalMegapixels, &_typicalBytesPerMegapixel, &_typicalCount);
        // The size most of the RAW photos have.
        NSCountedSet<NSNumber *> *sizes = [NSCountedSet set];
        for (POPhotoItem *item in _raws) [sizes addObject:@((NSInteger)llround(item.pixelWidth * (double)item.pixelHeight / 1e6))];
        for (NSNumber *size in sizes) if ([sizes countForObject:size] > [sizes countForObject:@(_rawMegapixels)]) _rawMegapixels = size.integerValue;
        _sizes = [NSMutableArray array];
        _sampled = [NSMutableDictionary dictionary];
        _probed = [NSMapTable strongToStrongObjectsMapTable];
    }
    return self;
}

static NSTextField *POSmallLabel(NSString *text) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.textColor = NSColor.secondaryLabelColor;
    return label;
}

static NSTextField *POHint(NSString *text) {
    NSTextField *hint = [NSTextField wrappingLabelWithString:text];
    hint.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    hint.textColor = NSColor.secondaryLabelColor;
    hint.selectable = NO;
    hint.preferredMaxLayoutWidth = 470;
    return hint;
}

/// The options of a checkbox, under it.
static NSStackView *POIndented(NSArray<NSView *> *views) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    stack.edgeInsets = NSEdgeInsetsMake(2, 22, 0, 0);
    return stack;
}

- (void)loadView {
    NSTextField *title = [NSTextField labelWithString:POL(@"Сжать")];
    title.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObjects:title,
        POHint(POL(@"Сжатые файлы занимают место оригиналов: RAW станет JPEG с тем же именем, видео останется под своим именем. Оригиналы уходят в Корзину — их можно вернуть оттуда, пока Корзина не очищена.")), nil];

    // Photos.
    if (_raws.count) {
        unsigned long long bytes = 0;
        for (POPhotoItem *item in _raws) bytes += item.fileSize;
        _photosCheckbox = [NSButton checkboxWithTitle:[NSString stringWithFormat:POL(@"RAW-фото: %@ · %@"), PONumber(_raws.count), POByteSize((long long)bytes)]
                                               target:self action:@selector(update)];
        _photosCheckbox.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold];
        _photosCheckbox.state = NSControlStateValueOn;
        _sizePopup = [NSPopUpButton new];
        // As most photos of the library first, then the usual sizes up to the RAW's own.
        for (NSNumber *mp in @[@(_typicalMegapixels), @12, @24, @48]) {
            NSInteger value = mp.integerValue;
            if (value <= 0 || (_rawMegapixels > 0 && value > _rawMegapixels) || [_sizes containsObject:mp]) continue;
            [_sizes addObject:mp];
            NSString *label = value == _typicalMegapixels && _typicalCount > 0
                ? [NSString stringWithFormat:POL(@"%@ МП — как большинство фото в медиатеке (%@)"), mp, PONumber(_typicalCount)]
                : _rawMegapixels > 0 && value >= _rawMegapixels ? [NSString stringWithFormat:POL(@"%@ МП — как в оригинале"), mp]
                : [NSString stringWithFormat:POL(@"%@ МП"), mp];
            [_sizePopup addItemWithTitle:label];
        }
        if (!_sizes.count) {
            [_sizes addObject:@(_rawMegapixels)];
            [_sizePopup addItemWithTitle:[NSString stringWithFormat:POL(@"%@ МП — как в оригинале"), @(_rawMegapixels)]];
        }
        _sizePopup.target = self;
        _sizePopup.action = @selector(sizeChanged:);
        _photoEstimate = POHint(@"");
        _photoEstimate.textColor = NSColor.labelColor;
        NSArray<NSView *> *photoViews = @[POSmallLabel(POL(@"Размер")), _sizePopup,
            POHint(POL(@"HDR сохраняется: JPEG с картой яркости (Ultra HDR, ISO 21496-1) — яркие места светятся на HDR-экранах, как в оригинале на iPhone. Дата, место и камера — как в оригинале.")),
            _photoEstimate];
        [views addObject:_photosCheckbox];
        [views addObject:POIndented(photoViews)];
    }

    // Videos.
    if (_allVideos.count) {
        unsigned long long bytes = 0;
        for (POPhotoItem *item in _allVideos) bytes += item.fileSize;
        _videosCheckbox = [NSButton checkboxWithTitle:[NSString stringWithFormat:POL(@"Видео: %@ · %@"), PONumber(_allVideos.count), POByteSize((long long)bytes)]
                                               target:self action:@selector(update)];
        _videosCheckbox.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold];
        _videosCheckbox.state = NSControlStateValueOn;
        _heightPopup = [NSPopUpButton new];
        NSArray<NSNumber *> *heights = POCompressionVideoHeights();
        for (NSNumber *height in heights) {
            [_heightPopup addItemWithTitle:height.integerValue == 2160 ? POL(@"4K (2160p)")
                                         : height.integerValue == POCompressionDefaultVideoHeight ? [NSString stringWithFormat:POL(@"%@p — рекомендуется"), height]
                                         : [NSString stringWithFormat:@"%@p", height]];
        }
        id savedHeight = [NSUserDefaults.standardUserDefaults objectForKey:POCompressVideoHeightKey];
        NSUInteger heightIndex = [heights indexOfObject:savedHeight ?: @(POCompressionDefaultVideoHeight)];
        [_heightPopup selectItemAtIndex:heightIndex == NSNotFound ? 1 : (NSInteger)heightIndex];
        _heightPopup.target = self;
        _heightPopup.action = @selector(update);
        _qualityPopup = [NSPopUpButton new];
        [_qualityPopup addItemsWithTitles:@[POL(@"Максимальное"), POL(@"Высокое — без видимых потерь"), POL(@"Экономное")]];
        id savedQuality = [NSUserDefaults.standardUserDefaults objectForKey:POCompressVideoQualityKey];
        [_qualityPopup selectItemAtIndex:MIN(MAX(savedQuality ? [savedQuality integerValue] : POCompressionDefaultVideoQuality, 0), 2)];
        _qualityPopup.target = self;
        _qualityPopup.action = @selector(update);
        _videoEstimate = POHint(@"");
        _videoEstimate.textColor = NSColor.labelColor;
        NSArray<NSView *> *videoViews = @[POSmallLabel(POL(@"Разрешение не больше")), _heightPopup, POSmallLabel(POL(@"Качество")), _qualityPopup,
            POHint(POL(@"HDR сохраняется: HEVC 10 бит с тем же описанием цвета (HLG, PQ). Звук, дата и место съёмки — как в оригинале. Видео, которые и так весят немного, не трогаются.")),
            _videoEstimate];
        [views addObject:_videosCheckbox];
        [views addObject:POIndented(videoViews)];
    }
    if (!_raws.count && !_allVideos.count) {
        [views addObject:POHint(POL(@"Среди выбранных файлов нет RAW-фото и видео — сжимать нечего. Обычные JPEG и HEIC уже сжаты."))];
    }
    _totalLabel = [NSTextField labelWithString:@""];
    _totalLabel.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold];
    [views addObject:_totalLabel];

    NSButton *cancel = [NSButton buttonWithTitle:POL(@"Отмена") target:self action:@selector(cancel:)];
    cancel.keyEquivalent = @"\e";
    _confirmButton = [NSButton buttonWithTitle:POL(@"Сжать") target:self action:@selector(confirm:)];
    _confirmButton.keyEquivalent = @"\r";
    NSStackView *buttons = [NSStackView stackViewWithViews:@[[NSView new], cancel, _confirmButton]];
    [views addObject:buttons];

    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    stack.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
    [stack setCustomSpacing:14 afterView:views[1]];
    if (_photoEstimate) [stack setCustomSpacing:16 afterView:_photoEstimate.superview];
    if (_videoEstimate) [stack setCustomSpacing:16 afterView:_videoEstimate.superview];
    [stack setCustomSpacing:16 afterView:_totalLabel];
    [buttons.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-40].active = YES;
    [stack.widthAnchor constraintEqualToConstant:560].active = YES;
    self.view = stack;
    [self update];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    [self sample];
    [self probe];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    _closed = YES;
}

- (NSInteger)megapixels {
    return _sizes.count ? _sizes[MAX(_sizePopup.indexOfSelectedItem, 0)].integerValue : 12;
}

- (NSInteger)videoHeight {
    return POCompressionVideoHeights()[MAX(_heightPopup.indexOfSelectedItem, 0)].integerValue;
}

- (NSInteger)videoQuality {
    return MAX(_qualityPopup.indexOfSelectedItem, 0);
}

- (NSArray<POPhotoItem *> *)photos {
    return _photosCheckbox.state == NSControlStateValueOn ? _raws : @[];
}

- (NSArray<NSArray *> *)videos {
    if (_videosCheckbox.state != NSControlStateValueOn) return @[];
    NSMutableArray<NSArray *> *videos = [NSMutableArray array];
    for (POPhotoItem *item in _allVideos) {
        POVideoInfo *info = [_probed objectForKey:item];
        POVideoJob *job = info ? POPlanVideo(info, self.videoHeight, self.videoQuality) : nil;
        if (job) [videos addObject:@[item, info, job]];
    }
    return videos;
}

- (void)sizeChanged:(id)sender {
    [self update];
    [self sample];
}

- (void)update {
    long long before = 0, after = 0;
    if (_raws.count) {
        NSNumber *sampled = _sampled[@(self.megapixels)];
        // The gain map adds about a tenth.
        double each = sampled ? sampled.doubleValue : self.megapixels * _typicalBytesPerMegapixel * 1.1;
        long long photosBefore = 0, photosAfter = (long long)(each * _raws.count);
        for (POPhotoItem *item in _raws) photosBefore += item.fileSize;
        _photoEstimate.stringValue = [NSString stringWithFormat:POL(@"Станет ≈ %@ — %@ на снимок, %@."), POByteSize(photosAfter), POByteSize((long long)each),
                                      sampled ? POL(@"по пробному сжатию") : POL(@"оценка по фото медиатеки, уточняется пробным сжатием…")];
        if (_photosCheckbox.state == NSControlStateValueOn) {
            before += photosBefore;
            after += photosAfter;
        }
    }
    if (_allVideos.count) {
        NSArray<NSArray *> *jobs = self.videos;
        long long videosBefore = 0, videosAfter = 0;
        for (NSArray *video in jobs) {
            videosBefore += (long long)((POPhotoItem *)video[0]).fileSize;
            videosAfter += [(POVideoJob *)video[2] estimatedSize];
        }
        NSString *text = jobs.count
            ? [NSString stringWithFormat:POL(@"Сожмутся %@: %@."), POCount(jobs.count, POL(@"видео"), POL(@"видео"), POL(@"видео")), POCompressionSaving(videosBefore, videosAfter)]
            : POL(@"Нечего сжимать: видео уже не больше этого размера и весят немного.");
        NSUInteger skipped = _probed.count - jobs.count;
        if (jobs.count && skipped > 0 && _videosCheckbox.state == NSControlStateValueOn) {
            text = [text stringByAppendingFormat:@" %@", [NSString stringWithFormat:POL(@"Остальные %@ и так компактные — не трогаются."), PONumber(skipped)]];
        }
        if (_probing) text = [text stringByAppendingFormat:@" %@", [NSString stringWithFormat:POL(@"Проверено %@ из %@…"), PONumber(_probeDone), PONumber(_allVideos.count)]];
        _videoEstimate.stringValue = text;
        before += videosBefore;
        after += videosAfter;
    }
    _totalLabel.stringValue = before > 0 ? [NSString stringWithFormat:POL(@"Итого: %@"), POCompressionSaving(before, after)] : @"";
    // While the videos are being read, only the photos can go.
    _confirmButton.enabled = !(_probing && _videosCheckbox.state == NSControlStateValueOn) && (self.photos.count > 0 || self.videos.count > 0);
}

/// Two RAW photos compressed in memory at the size chosen, to say how much they will weigh.
- (void)sample {
    NSInteger megapixels = self.megapixels;
    if (!_raws.count || _sampled[@(megapixels)]) return;
    // Spread over the selection: the first ones are often of one day.
    NSOrderedSet<POPhotoItem *> *trial = [NSOrderedSet orderedSetWithArray:@[_raws[_raws.count / 3], _raws[_raws.count * 2 / 3]]];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        double total = 0;
        NSUInteger count = 0;
        for (POPhotoItem *item in trial) {
            @autoreleasepool {
                NSData *jpeg = POCompressRawPhoto(item.url, megapixels, NULL, NULL);
                if (jpeg) {
                    total += jpeg.length;
                    count++;
                }
            }
        }
        if (!count) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) me = weakSelf;
            if (!me || me->_closed) return;
            me->_sampled[@(megapixels)] = @(total / count);
            [me update];
        });
    });
}

/// Every video read (size, frame rate, bitrate, HDR), a few at a time, the estimate growing as it goes.
- (void)probe {
    if (!_allVideos.count || _probing) return;
    _probing = YES;
    _probeDone = 0;
    [self update];
    NSArray<POPhotoItem *> *videos = _allVideos;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSOperationQueue *queue = [NSOperationQueue new];
        queue.maxConcurrentOperationCount = 4;
        for (POPhotoItem *item in videos) {
            [queue addOperationWithBlock:^{
                typeof(self) alive = weakSelf;
                if (!alive || alive->_closed) return;
                POVideoInfo *info = POProbeVideo(item.url);
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(self) me = weakSelf;
                    if (!me) return;
                    if (info) [me->_probed setObject:info forKey:item];
                    if (++me->_probeDone % 25 == 0) [me update];
                });
            }];
        }
        [queue waitUntilAllOperationsAreFinished];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) me = weakSelf;
            if (!me) return;
            me->_probing = NO;
            [me update];
        });
    });
}

- (void)cancel:(id)sender {
    _closed = YES;
    [self dismissController:nil];
}

- (void)confirm:(id)sender {
    _closed = YES;
    if (_allVideos.count) {
        [NSUserDefaults.standardUserDefaults setInteger:self.videoHeight forKey:POCompressVideoHeightKey];
        [NSUserDefaults.standardUserDefaults setInteger:self.videoQuality forKey:POCompressVideoQualityKey];
    }
    [self dismissController:nil];
    if (self.completion) self.completion(self);
}

@end
