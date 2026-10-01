#import <Foundation/Foundation.h>
#import "POPhotoItem.h"

NS_ASSUME_NONNULL_BEGIN

/// Russian name of a Vision classification label ("beach" → "пляж"); the identifier itself when there is none.
FOUNDATION_EXPORT NSString *POLabelDisplayName(NSString *identifier);

/// Lower-cased words of a search query.
FOUNDATION_EXPORT NSArray<NSString *> *POSearchTokens(NSString *query);

/// YES when every token begins a word of one of the item's labels (Russian or English) or occurs in its path.
FOUNDATION_EXPORT BOOL POItemMatchesTokens(POPhotoItem *item, NSArray<NSString *> *tokens);

NS_ASSUME_NONNULL_END
