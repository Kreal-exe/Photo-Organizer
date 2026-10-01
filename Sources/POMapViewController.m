#import "POMapViewController.h"
#import "POStrings.h"
#import <MapKit/MapKit.h>

@interface POPhotoAnnotation : NSObject <MKAnnotation>
@property (nonatomic, strong) POPhotoItem *item;
@end

@implementation POPhotoAnnotation

- (CLLocationCoordinate2D)coordinate {
    return CLLocationCoordinate2DMake(self.item.latitude, self.item.longitude);
}

- (NSString *)title {
    return self.item.url.lastPathComponent;
}

@end

static NSString *const POClusterID = @"photos";

@interface POMapViewController () <MKMapViewDelegate>
@end

@implementation POMapViewController {
    MKMapView *_mapView;
    NSArray<POPhotoItem *> *_items;
    NSTextField *_emptyLabel;
}

- (void)loadView {
    _mapView = [MKMapView new];
    _mapView.delegate = self;
    _mapView.showsZoomControls = YES;
    _mapView.showsCompass = YES;
    _mapView.translatesAutoresizingMaskIntoConstraints = NO;
    [_mapView registerClass:MKMarkerAnnotationView.class forAnnotationViewWithReuseIdentifier:@"photo"];
    [_mapView registerClass:MKMarkerAnnotationView.class forAnnotationViewWithReuseIdentifier:MKMapViewDefaultClusterAnnotationViewReuseIdentifier];

    _emptyLabel = [NSTextField wrappingLabelWithString:POL(@"Ни у одного фото или видео здесь нет координат съёмки.")];
    _emptyLabel.font = [NSFont systemFontOfSize:15 weight:NSFontWeightMedium];
    _emptyLabel.alignment = NSTextAlignmentCenter;
    _emptyLabel.drawsBackground = YES;
    _emptyLabel.backgroundColor = [NSColor.windowBackgroundColor colorWithAlphaComponent:0.9];
    _emptyLabel.hidden = YES;
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *view = [NSView new];
    [view addSubview:_mapView];
    [view addSubview:_emptyLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_mapView.topAnchor constraintEqualToAnchor:view.topAnchor],
        [_mapView.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
        [_mapView.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [_mapView.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [_emptyLabel.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [_emptyLabel.centerYAnchor constraintEqualToAnchor:view.centerYAnchor],
        [_emptyLabel.widthAnchor constraintLessThanOrEqualToConstant:420],
    ]];
    self.view = view;
}

- (void)setItems:(NSArray<POPhotoItem *> *)items {
    (void)self.view;
    NSArray<POPhotoItem *> *located = [items filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"hasLocation == YES"]];
    if ([located isEqualToArray:_items]) return;
    _items = located;
    [_mapView removeAnnotations:_mapView.annotations];
    NSMutableArray<POPhotoAnnotation *> *annotations = [NSMutableArray arrayWithCapacity:located.count];
    for (POPhotoItem *item in located) {
        POPhotoAnnotation *annotation = [POPhotoAnnotation new];
        annotation.item = item;
        [annotations addObject:annotation];
    }
    [_mapView addAnnotations:annotations];
    _emptyLabel.hidden = located.count > 0;
    if (annotations.count) [_mapView showAnnotations:annotations animated:NO];
}

#pragma mark - MKMapViewDelegate

- (MKAnnotationView *)mapView:(MKMapView *)mapView viewForAnnotation:(id<MKAnnotation>)annotation {
    if ([annotation isKindOfClass:MKClusterAnnotation.class]) {
        MKMarkerAnnotationView *view = (MKMarkerAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:MKMapViewDefaultClusterAnnotationViewReuseIdentifier forAnnotation:annotation];
        view.glyphText = PONumber(((MKClusterAnnotation *)annotation).memberAnnotations.count);
        view.markerTintColor = NSColor.controlAccentColor;
        view.canShowCallout = NO;
        return view;
    }
    if (![annotation isKindOfClass:POPhotoAnnotation.class]) return nil;
    MKMarkerAnnotationView *view = (MKMarkerAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:@"photo" forAnnotation:annotation];
    view.clusteringIdentifier = POClusterID;
    view.glyphImage = [NSImage imageWithSystemSymbolName:((POPhotoAnnotation *)annotation).item.isVideo ? @"video.fill" : @"photo.fill" accessibilityDescription:nil];
    view.markerTintColor = NSColor.systemOrangeColor;
    view.canShowCallout = NO;
    return view;
}

- (void)mapView:(MKMapView *)mapView didSelectAnnotationView:(MKAnnotationView *)view {
    id<MKAnnotation> annotation = view.annotation;
    NSMutableArray<POPhotoItem *> *items = [NSMutableArray array];
    if ([annotation isKindOfClass:MKClusterAnnotation.class]) {
        for (id<MKAnnotation> member in ((MKClusterAnnotation *)annotation).memberAnnotations) {
            if ([member isKindOfClass:POPhotoAnnotation.class]) [items addObject:((POPhotoAnnotation *)member).item];
        }
    } else if ([annotation isKindOfClass:POPhotoAnnotation.class]) {
        [items addObject:((POPhotoAnnotation *)annotation).item];
    }
    [mapView deselectAnnotation:annotation animated:NO];
    [items sortUsingComparator:^NSComparisonResult(POPhotoItem *a, POPhotoItem *b) { return [a.date compare:b.date]; }];
    if (items.count && self.onSelectItems) self.onSelectItems(items);
}

@end
