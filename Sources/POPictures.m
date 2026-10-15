#import "POPictures.h"
#import "POAnalyzer.h"
#import "POMediaTypes.h"
#import "POObjectIndex.h"
#import "POScreenshots.h"
#import <Accelerate/Accelerate.h>

/// What the labels call graphic (see POGraphicScore) to be a sure picture, and the most a sure photo may have.
static const float POSureGraphic = 0.6f, POSurePhoto = 0.1f;
static const NSUInteger POMinimumExamples = 30, POMaximumExamples = 6000, POEpochs = 300;
static const float POLearningRate = 0.5f, PORegularization = 0.001f, POThreshold = 0.5f;
/// How many sure examples one file the user marked counts for.
static const NSUInteger POMarkWeight = 10;

#pragma mark - Model

/// A logistic regression over standardised prints: (print − mean) × scale · weights + bias.
typedef struct {
    NSUInteger dimension;
    float *mean, *scale, *weights;   // weights: dimension + 1, the bias last
} POPictureModel;

static void POFreeModel(POPictureModel *model) {
    free(model->mean);
    free(model->scale);
    free(model->weights);
}

/// Standardises `rows` prints in place with the model's mean and scale.
static void POStandardise(const POPictureModel *model, float *prints, NSUInteger rows) {
    NSUInteger dimension = model->dimension;
    for (NSUInteger d = 0; d < dimension; d++) {
        float negativeMean = -model->mean[d];
        vDSP_vsadd(prints + d, dimension, &negativeMean, prints + d, dimension, rows);
        vDSP_vsmul(prints + d, dimension, model->scale + d, prints + d, dimension, rows);
    }
}

/// Trains on `positives` and `negatives` (each a run of prints, `dimension` floats apiece), both classes weighted
/// equally, by gradient descent over every example at once.
static POPictureModel POTrainModel(NSData *positives, NSData *negatives, NSUInteger dimension) {
    NSUInteger positiveCount = positives.length / (dimension * sizeof(float)), negativeCount = negatives.length / (dimension * sizeof(float));
    NSUInteger count = positiveCount + negativeCount;
    POPictureModel model = {dimension, calloc(dimension, sizeof(float)), calloc(dimension, sizeof(float)), calloc(dimension + 1, sizeof(float))};
    float *x = malloc(count * dimension * sizeof(float)), *y = malloc(count * sizeof(float));
    memcpy(x, positives.bytes, positives.length);
    memcpy(x + positiveCount * dimension, negatives.bytes, negatives.length);
    for (NSUInteger i = 0; i < count; i++) y[i] = i < positiveCount ? 1 : 0;

    // Standardised, so that every number of the print counts alike whatever its usual range.
    for (NSUInteger d = 0; d < dimension; d++) {
        float meanSquare = 0;
        vDSP_meanv(x + d, dimension, model.mean + d, count);
        vDSP_measqv(x + d, dimension, &meanSquare, count);
        float variance = meanSquare - model.mean[d] * model.mean[d];
        model.scale[d] = 1 / sqrtf(MAX(variance, 1e-8f));
    }
    POStandardise(&model, x, count);

    float *weights = model.weights, *scores = malloc(count * sizeof(float)), *gradient = malloc(dimension * sizeof(float));
    float positiveWeight = 0.5f / positiveCount, negativeWeight = 0.5f / negativeCount;
    for (NSUInteger epoch = 0; epoch < POEpochs; epoch++) {
        cblas_sgemv(CblasRowMajor, CblasNoTrans, (int)count, (int)dimension, 1, x, (int)dimension, weights, 1, 0, scores, 1);
        float biasGradient = 0;
        for (NSUInteger i = 0; i < count; i++) {
            float probability = 1 / (1 + expf(-(scores[i] + weights[dimension])));
            scores[i] = (probability - y[i]) * (i < positiveCount ? positiveWeight : negativeWeight);
            biasGradient += scores[i];
        }
        cblas_sgemv(CblasRowMajor, CblasTrans, (int)count, (int)dimension, 1, x, (int)dimension, scores, 1, 0, gradient, 1);
        for (NSUInteger d = 0; d < dimension; d++) weights[d] -= POLearningRate * (gradient[d] + PORegularization * weights[d]);
        weights[dimension] -= POLearningRate * biasGradient;
    }
    free(scores);
    free(gradient);
    free(x);
    free(y);
    return model;
}

/// The probability of being a picture for each of `rows` prints (standardised in place).
static void POPredict(const POPictureModel *model, float *prints, NSUInteger rows, float *probabilities) {
    POStandardise(model, prints, rows);
    cblas_sgemv(CblasRowMajor, CblasNoTrans, (int)rows, (int)model->dimension, 1, prints, (int)model->dimension, model->weights, 1, 0,
                probabilities, 1);
    for (NSUInteger i = 0; i < rows; i++) probabilities[i] = 1 / (1 + expf(-(probabilities[i] + model->weights[model->dimension])));
}

#pragma mark - Examples

/// The sure examples of every library opened — their prints, as float16, under their cache keys — kept in Application
/// Support/Photo Organizer/picture-examples.plist: a folder of saved pictures has no camera photos to learn from, and a
/// camera roll few pictures, so each lends the other its examples. The prints are kept here rather than looked up in
/// the object index, so that what was learnt survives forgetting the analysis and moving to another library. What the
/// user said a file is ("Это картинка" / "Это фото") is kept there too.
static NSURL *POExamplesURL(void) {
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                                                 appropriateForURL:nil create:YES error:NULL];
    return [support URLByAppendingPathComponent:@"Photo Organizer/picture-examples.plist"];
}

static NSData *POHalfPrint(NSData *print, NSUInteger dimension) {
    NSMutableData *half = [NSMutableData dataWithLength:dimension * 2];
    vImage_Buffer source = {(void *)print.bytes, 1, dimension, dimension * 4}, destination = {half.mutableBytes, 1, dimension, dimension * 2};
    vImageConvert_PlanarFtoPlanar16F(&source, &destination, 0);
    return half;
}

/// The prints of `examples` (key → float16 print) one after another as float32, at most `limit` of them, picked the
/// same way every time — the ones the user marked first, each counted POMarkWeight times.
static NSData *POExamplePrints(NSDictionary<NSString *, NSData *> *examples, NSDictionary<NSString *, NSNumber *> *marks,
                               NSUInteger dimension, NSUInteger limit) {
    NSMutableArray<NSString *> *keys = [[examples.allKeys sortedArrayUsingSelector:@selector(compare:)] mutableCopy];
    uint64_t state = 1;
    for (NSUInteger i = keys.count; i > 1; i--) {
        state = state * 6364136223846793005ULL + 1442695040888963407ULL;
        [keys exchangeObjectAtIndex:i - 1 withObjectAtIndex:(NSUInteger)((state >> 33) % i)];
    }
    [keys sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return (marks[b] != nil) - (marks[a] != nil);
    }];
    NSMutableData *prints = [NSMutableData data];
    for (NSString *key in keys) {
        NSData *half = examples[key];
        if (half.length != dimension * 2) continue;
        NSMutableData *print = [NSMutableData dataWithLength:dimension * 4];
        vImage_Buffer source = {(void *)half.bytes, 1, dimension, dimension * 2}, destination = {print.mutableBytes, 1, dimension, dimension * 4};
        vImageConvert_Planar16FtoPlanarF(&source, &destination, 0);
        for (NSUInteger copy = 0; copy < (marks[key] ? POMarkWeight : 1); copy++) [prints appendData:print];
        if (prints.length / (dimension * 4) >= limit) break;
    }
    return prints;
}

/// Everything remembered — "pictures" and "photos" (key → float16 print), "marks" (key → what the user said) — read
/// and written under one lock, as the classification and the user's marks may come at the same time.
static NSObject *POExamplesLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static NSMutableDictionary<NSString *, NSMutableDictionary *> *POLoadExamples(void) {
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfURL:POExamplesURL()];
    NSMutableDictionary *examples = [NSMutableDictionary dictionary];
    for (NSString *part in @[@"pictures", @"photos", @"marks"]) {
        examples[part] = [stored[part] isKindOfClass:NSDictionary.class] ? [stored[part] mutableCopy] : [NSMutableDictionary dictionary];
    }
    return examples;
}

static void POSaveExamples(NSDictionary *examples) {
    [NSFileManager.defaultManager createDirectoryAtURL:POExamplesURL().URLByDeletingLastPathComponent withIntermediateDirectories:YES
                                            attributes:nil error:NULL];
    [examples writeToURL:POExamplesURL() atomically:YES];
}

/// Files the user marked go into their class whatever the limits, and out of the other one.
static void POAddMarkedExample(NSMutableDictionary *examples, NSString *key, BOOL picture, NSData *print, NSUInteger dimension) {
    [examples[picture ? @"photos" : @"pictures"] removeObjectForKey:key];
    if (print) examples[picture ? @"pictures" : @"photos"][key] = POHalfPrint(print, dimension);
}

#pragma mark - Classification

NSArray *POClassifyPictures(NSArray<POPhotoItem *> *items) {
    NSUInteger dimension = POObjectIndex.printLength;
    NSMutableArray<NSNumber *> *candidates = [NSMutableArray array];
    NSMutableData *printsData = [NSMutableData data];
    NSData *positives, *negatives;
    @synchronized (POExamplesLock()) {
        NSMutableDictionary *examples = POLoadExamples();
        NSMutableDictionary<NSString *, NSData *> *pictures = examples[@"pictures"], *photos = examples[@"photos"];
        NSDictionary<NSString *, NSNumber *> *marks = examples[@"marks"];
        BOOL changed = NO;
        for (NSUInteger i = 0; i < items.count; i++) {
            POPhotoItem *item = items[i];
            if (item.isVideo || item.isCloudOnly || POIsGooglePhotosCreation(item) || POIsScreenshot(item)) continue;
            NSDictionary *labels = item.labels;
            NSString *key = labels ? [POAnalyzer cacheKeyForURL:item.url] : nil;
            NSData *print = key ? [POObjectIndex.sharedIndex wholePrintForKey:key] : nil;
            if (!print) continue;
            [candidates addObject:@(i)];
            [printsData appendData:print];
            NSNumber *mark = marks[key];
            if (mark) {
                // Marked before its print was known.
                if (!(mark.boolValue ? pictures : photos)[key]) {
                    POAddMarkedExample(examples, key, mark.boolValue, print, dimension);
                    changed = YES;
                }
                continue;
            }
            // Remembered up to twice what one training takes, so that a large library does not crowd out the others.
            float graphic = POGraphicScore(labels);
            BOOL dated = item.dateSource == PODateSourceEXIF;
            if (graphic >= POSureGraphic && !dated && !item.hasLocation && !POLooksPhotographed(labels)) {
                if (!pictures[key] && pictures.count < 2 * POMaximumExamples) {
                    pictures[key] = POHalfPrint(print, dimension);
                    changed = YES;
                }
            } else if (graphic < POSurePhoto && (dated || POLooksPhotographed(labels))) {
                if (!photos[key] && photos.count < 2 * POMaximumExamples) {
                    photos[key] = POHalfPrint(print, dimension);
                    changed = YES;
                }
            }
        }
        if (changed) POSaveExamples(examples);
        positives = POExamplePrints(pictures, marks, dimension, POMaximumExamples);
        negatives = POExamplePrints(photos, marks, dimension, POMaximumExamples);
    }
    NSUInteger printSize = dimension * sizeof(float);
    if (positives.length / printSize < POMinimumExamples || negatives.length / printSize < POMinimumExamples) return nil;

    POPictureModel model = POTrainModel(positives, negatives, dimension);
    NSUInteger rows = candidates.count;
    float *probabilities = malloc(MAX(rows, 1) * sizeof(float));
    POPredict(&model, printsData.mutableBytes, rows, probabilities);
    POFreeModel(&model);
    NSMutableArray *verdicts = [NSMutableArray arrayWithCapacity:items.count];
    for (NSUInteger i = 0; i < items.count; i++) [verdicts addObject:NSNull.null];
    for (NSUInteger row = 0; row < rows; row++) {
        // A photo of people, animals or the sky, with nothing drawn about it, stays a photo whatever the model says:
        // taking a family photo away from the photos is worse than leaving a postcard among them.
        NSUInteger index = candidates[row].unsignedIntegerValue;
        // The model alone never makes a picture: it takes messenger photos, which have lost every bit of camera
        // metadata, for pictures too. What it adds to the labels is a postcard told by its wishes — text read in it.
        POPhotoItem *item = items[index];
        // Where a person, an animal or a landscape is seen, the text has to be a postcard's wishes, not a photographed
        // whiteboard or screen.
        BOOL byModel = probabilities[row] >= POThreshold &&
                       (POLooksPhotographed(item.labels) ? POHasPostcardWords(item.text) : POLetterCount(item.text) >= POPostcardLetters);
        verdicts[index] = @(POIsPictureByLabels(item) || byModel);
    }
    free(probabilities);
    return verdicts;
}

void POApplyPictureVerdicts(NSArray<POPhotoItem *> *items, NSArray *verdicts) {
    for (NSUInteger i = 0; i < items.count; i++) {
        id verdict = i < verdicts.count ? verdicts[i] : nil;
        items[i].pictureVerdict = [verdict isKindOfClass:NSNumber.class] ? verdict : nil;
    }
}

#pragma mark - Marks

NSArray *POPictureMarks(NSArray<POPhotoItem *> *items) {
    NSDictionary<NSString *, NSNumber *> *marks;
    @synchronized (POExamplesLock()) {
        marks = POLoadExamples()[@"marks"];
    }
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:items.count];
    for (POPhotoItem *item in items) {
        NSString *key = marks.count ? [POAnalyzer cacheKeyForURL:item.url] : nil;
        [result addObject:(key ? marks[key] : nil) ?: NSNull.null];
    }
    return result;
}

void POMarkPictures(NSArray<POPhotoItem *> *items, BOOL pictures) {
    NSUInteger dimension = POObjectIndex.printLength;
    for (POPhotoItem *item in items) item.pictureMark = @(pictures);
    @synchronized (POExamplesLock()) {
        NSMutableDictionary *examples = POLoadExamples();
        for (POPhotoItem *item in items) {
            NSString *key = [POAnalyzer cacheKeyForURL:item.url];
            if (!key) continue;
            examples[@"marks"][key] = @(pictures);
            POAddMarkedExample(examples, key, pictures, [POObjectIndex.sharedIndex wholePrintForKey:key], dimension);
        }
        POSaveExamples(examples);
    }
}
