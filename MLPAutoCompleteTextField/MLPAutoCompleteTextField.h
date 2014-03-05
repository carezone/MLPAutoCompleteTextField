//
//  MLPAutoCompleteTextField.h
//
//  Adapted by Christoph Zelazowski on 01/10/14.
//  Based on work created by Eddy Borja on 12/29/12.
//  Copyright (c) 2013 Mainloop LLC. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the
//  "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish,
//  distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to
//  the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//  MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR
//  ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH
//  THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

#import <UIKit/UIKit.h>
#import "MLPAutoCompleteTextFieldDataSource.h"
#import "MLPAutoCompleteTextFieldDelegate.h"

@protocol MLPAutoCompleteSortOperationDelegate <NSObject>
- (void)autoCompleteTermsDidSort:(NSArray *)completions;
@end


@protocol MLPAutoCompleteFetchOperationDelegate <NSObject>
- (void)autoCompleteTermsDidFetch:(NSDictionary *)fetchInfo;
@end


@interface MLPAutoCompleteTextField : UITextField
    <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UICollectionViewDelegate,
        MLPAutoCompleteSortOperationDelegate, MLPAutoCompleteFetchOperationDelegate>

@property (strong, readonly) UICollectionView *autoCompleteCollectionView;

@property (weak) IBOutlet id <MLPAutoCompleteTextFieldDataSource> autoCompleteDataSource;
@property (weak) IBOutlet id <MLPAutoCompleteTextFieldDelegate> autoCompleteDelegate;

@property (strong) id autoCompleteMenuItem;

// default is 0.1, if you fetch from a web service you may want this higher to prevent multiple calls happening very quickly.
@property (assign) NSTimeInterval autoCompleteFetchRequestDelay;

@property (assign) BOOL sortAutoCompleteSuggestionsByClosestMatch;
@property (assign) BOOL applyBoldEffectToAutoCompleteSuggestions;
@property (assign) BOOL reverseAutoCompleteSuggestionsBoldEffect;
@property (assign) BOOL showTextFieldDropShadowWhenAutoCompleteIsOpen;

// only applies for drop down style autocomplete tables.
@property (assign) BOOL showAutoCompleteWhenEditingBegins;

@property (assign) BOOL disableAutoCompleteUserInteractionWhileFetching;
@property (assign) BOOL disableAutoCompleteReplacement;

// if set to TRUE, the autocomplete table will appear as a keyboard input accessory view rather than a drop down.
@property (assign) BOOL autoCompleteAppearsAsKeyboardAccessory;

@property (assign) UICollectionViewScrollDirection autoCompleteScrollDirection;

@property (assign) BOOL autoCompleteViewHidden;

@property (assign) CGFloat autoCompleteFontSize;
@property (strong) NSString *autoCompleteBoldFontName;
@property (strong) NSString *autoCompleteRegularFontName;

@property (assign) NSInteger maximumNumberOfAutoCompleteRows;
@property (assign) CGFloat autoCompleteRowHeight;
@property (assign) CGSize autoCompleteOriginOffset;

// only applies for drop down style autocomplete tables.
@property (assign) CGFloat autoCompleteCornerRadius;

@property (nonatomic, assign) UIEdgeInsets autoCompleteContentInsets;
@property (nonatomic, assign) UIEdgeInsets autoCompleteScrollIndicatorInsets;
@property (nonatomic, strong) UIColor *autoCompleteBorderColor;
@property (nonatomic, assign) CGFloat autoCompleteBorderWidth;
@property (nonatomic, strong) UIColor *autoCompleteBackgroundColor;
@property (strong) UIColor *autoCompleteCellBackgroundColor;
@property (strong) UIColor *autoCompleteCellTextColor;
@property (strong) UIColor *autoCompleteCellBoldTextColor;

- (void)registerAutoCompleteCellNib:(UINib *)nib forCellReuseIdentifier:(NSString *)reuseIdentifier;
- (void)registerAutoCompleteCellClass:(Class)cellClass forCellReuseIdentifier:(NSString *)reuseIdentifier;

@end
