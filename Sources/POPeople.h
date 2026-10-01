#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import "POPhotoItem.h"

NS_ASSUME_NONNULL_BEGIN

/// A group of faces that look like one person, and the files they appear in.
@interface POPerson : NSObject
/// Stable while the app runs: the name for named people, "#n" otherwise.
@property (nonatomic, readonly, copy) NSString *key;
/// "Человек 3" until the user names the group.
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly, getter=isNamed) BOOL named;
@property (nonatomic, readonly, copy) NSArray<POPhotoItem *> *items;
/// The files of `items` in which this person is the only one: every face found in them is theirs.
@property (nonatomic, readonly, copy) NSArray<POPhotoItem *> *soloItems;
@property (nonatomic, readonly) NSUInteger faceCount;
/// The photo that shows this person most typically — preferably one where they are alone.
@property (nonatomic, readonly, nullable) POPhotoItem *representativeItem;
@end

/// Groups the faces found by the analyzer into people. Names given by the user are remembered together with
/// what the face looks like, so the same person is recognised again in another folder or after a rescan.
@interface POPeople : NSObject

/// Blocking; call off the main thread. People with too few photos to be worth listing are left out; the result
/// is sorted by number of files, named people first.
+ (NSArray<POPerson *> *)peopleInItems:(NSArray<POPhotoItem *> *)items;

/// A small square picture of the person's face, cut from their representative photo. `completion` is called
/// on the main queue — at once when the picture is already known — with nil when no face could be cut out.
+ (void)faceThumbnailForPerson:(POPerson *)person completion:(void (^)(NSImage *_Nullable thumbnail))completion;

/// Names (or renames) a person. An empty name forgets the name.
+ (void)setName:(NSString *)name forPerson:(POPerson *)person;

@end

NS_ASSUME_NONNULL_END
