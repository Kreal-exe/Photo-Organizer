#import "POModel.h"
#import "POStrings.h"
#import "POHuggingFace.h"
#import "POMLXRuntime.h"
#import "POSettings.h"

@implementation POModel

+ (instancetype)modelWithIdentifier:(NSString *)identifier title:(NSString *)title summary:(NSString *)summary license:(NSString *)license
                            backend:(POModelBackend)backend files:(NSArray<NSString *> *)files byteSize:(long long)byteSize
                          inputSize:(NSInteger)inputSize centerCrop:(BOOL)centerCrop {
    POModel *model = [POModel new];
    model->_identifier = [identifier copy];
    model->_title = [title copy];
    model->_summary = [summary copy];
    model->_license = [license copy];
    model->_backend = backend;
    model->_files = [files copy];
    model->_byteSize = byteSize;
    model->_inputSize = inputSize;
    model->_centerCrop = centerCrop;
    return model;
}

+ (NSArray<POModel *> *)allModels {
    static NSArray<POModel *> *models;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        models = @[
            [self modelWithIdentifier:@"Marqo/nsfw-image-detection-384"
                                title:@"Marqo NSFW 384"
                              summary:POL(@"Маленькая и быстрая (ViT-tiny, 384 px). Хороший выбор по умолчанию.")
                              license:@"Apache-2.0"
                              backend:POModelBackendMLX
                                files:@[@"config.json", @"model.safetensors"]
                             byteSize:22405349 inputSize:384 centerCrop:YES],
            [self modelWithIdentifier:@"Falconsai/nsfw_image_detection"
                                title:@"Falconsai NSFW"
                              summary:POL(@"Самая популярная (ViT-base, 224 px). В 15 раз больше и медленнее.")
                              license:@"Apache-2.0"
                              backend:POModelBackendMLX
                                files:@[@"config.json", @"preprocessor_config.json", @"model.safetensors"]
                             byteSize:343225017 inputSize:224 centerCrop:NO],
            [self modelWithIdentifier:@"AdamCodd/vit-base-nsfw-detector"
                                title:@"AdamCodd ViT NSFW"
                              summary:POL(@"Крупная и самая медленная (ViT-base, 384 px), видит мелкие детали.")
                              license:@"Apache-2.0"
                              backend:POModelBackendMLX
                                files:@[@"config.json", @"preprocessor_config.json", @"model.safetensors"]
                             byteSize:344392275 inputSize:384 centerCrop:NO],
            [self modelWithIdentifier:@"InspiratioNULL/image-safety-classifier-s-CoreML"
                                title:@"Image Safety Classifier S"
                              summary:POL(@"Работает через Core ML без Python, подходит и для Intel (SwiftFormer, 224 px).")
                              license:@"MIT"
                              backend:POModelBackendCoreML
                                files:@[@"ImageSafetyClassifier.mlpackage/Manifest.json",
                                        @"ImageSafetyClassifier.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                                        @"ImageSafetyClassifier.mlpackage/Data/com.apple.CoreML/weights/weight.bin"]
                             byteSize:22702624 inputSize:224 centerCrop:YES],
        ];
    });
    return models;
}

+ (POModel *)faceModel {
    static POModel *model;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        model = [self modelWithIdentifier:@"gaunernst/vit_tiny_patch8_112.arcface_ms1mv3"
                                    title:@"ArcFace ViT-tiny"
                                  summary:POL(@"Превращает лицо в набор чисел, по которому похожие лица собираются в группы (ViT-tiny, 112 px).")
                                  license:POL(@"не указана автором")
                                  backend:POModelBackendMLX
                                    files:@[@"config.json", @"model.safetensors"]
                                 byteSize:22064736 inputSize:112 centerCrop:NO];
    });
    return model;
}

+ (POModel *)modelWithIdentifier:(NSString *)identifier {
    for (POModel *model in self.allModels) {
        if ([model.identifier isEqualToString:identifier]) return model;
    }
    return nil;
}

+ (POModel *)recommendedModel {
    return POMLXRuntime.isSupported ? self.allModels.firstObject : self.allModels.lastObject;
}

+ (POModel *)selectedModel {
    POModel *model = [self modelWithIdentifier:POSettings.nudityModelIdentifier];
    return model.isSupported ? model : self.recommendedModel;
}

- (BOOL)isSupported {
    return self.backend != POModelBackendMLX || POMLXRuntime.isSupported;
}

- (NSURL *)snapshotURL {
    return [POHuggingFace snapshotURLForRepo:self.identifier files:self.files];
}

- (BOOL)isReady {
    if (!self.isSupported || !self.snapshotURL) return NO;
    return self.backend != POModelBackendMLX || POMLXRuntime.isInstalled;
}

@end
