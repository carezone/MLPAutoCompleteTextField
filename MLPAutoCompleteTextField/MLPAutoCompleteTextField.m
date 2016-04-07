//
//  MLPAutoCompleteTextField.m
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

#import "MLPAutoCompleteTextField.h"
#import "MLPAutoCompletionObject.h"
#import "MLPAutoCompleteCell.h"
#import "NSString+Levenshtein.h"
#import <QuartzCore/QuartzCore.h>

static NSString *kSortInputStringKey = @"sortInputString";
static NSString *kSortEditDistancesKey = @"editDistances";
static NSString *kSortObjectKey = @"sortObject";
static NSString *kKeyboardAccessoryInputKeyPath = @"autoCompleteAppearsAsKeyboardAccessory";
static NSTimeInterval kDefaultAutoCompleteRequestDelay = 0.1;


@interface MLPAutoCompleteSortOperation: NSOperation

@property (strong) NSString *incompleteString;
@property (strong) NSArray *possibleCompletions;
@property (strong) id <MLPAutoCompleteSortOperationDelegate> delegate;
@property (strong) NSDictionary *boldTextAttributes;
@property (strong) NSDictionary *regularTextAttributes;

- (id)initWithDelegate:(id<MLPAutoCompleteSortOperationDelegate>)aDelegate incompleteString:(NSString *)string
    possibleCompletions:(NSArray *)possibleStrings;

- (NSArray *)sortedCompletionsForString:(NSString *)inputString withPossibleStrings:(NSArray *)possibleTerms;

@end

#pragma mark -

static NSString *kFetchedTermsKey = @"terms";
static NSString *kFetchedStringKey = @"fetchInputString";


@interface MLPAutoCompleteFetchOperation: NSOperation

@property (strong) NSString *incompleteString;
@property (strong) MLPAutoCompleteTextField *textField;
@property (strong) id <MLPAutoCompleteFetchOperationDelegate> delegate;
@property (strong) id <MLPAutoCompleteTextFieldDataSource> dataSource;

- (id)initWithDelegate:(id<MLPAutoCompleteFetchOperationDelegate>)aDelegate
    completionsDataSource:(id<MLPAutoCompleteTextFieldDataSource>)aDataSource autoCompleteTextField:(MLPAutoCompleteTextField *)aTextField;

@end

#pragma mark -

static NSString *kBorderStyleKeyPath = @"borderStyle";
static NSString *kAutoCompleteCollectionViewHiddenKeyPath = @"autoCompleteCollectionView.hidden";
static NSString *kBackgroundColorKeyPath = @"backgroundColor";
static NSString *kDefaultAutoCompleteCellIdentifier = @"defaultAutoCompleteCellIdentifier";
static NSString *kMaximumNumberOfAutoCompleteRowsKeyPath = @"maximumNumberOfAutoCompleteRows";
static NSString *kAutoCompleteScrollDirectionKeyPath = @"autoCompleteScrollDirection";

@interface MLPAutoCompleteTextField ()

@property (strong, readwrite) UICollectionView *autoCompleteCollectionView;
@property (strong, readonly) MLPAutoCompleteCell *sizingCollectionViewCell;
@property (strong) NSArray *autoCompleteSuggestions;
@property (strong) NSOperationQueue *autoCompleteSortQueue;
@property (strong) NSOperationQueue *autoCompleteFetchQueue;
@property (strong) NSString *reuseIdentifier;
@property (assign) CGColorRef originalShadowColor;
@property (assign) CGSize originalShadowOffset;
@property (assign) CGFloat originalShadowOpacity;

@end


@implementation MLPAutoCompleteTextField

#pragma mark - Lifecycle

// Note: Since initWithFrame: is the designated initializer for the UIView class, do *not* override the init method.
// Otherwise [self initialize] will get called twice, add we add self as key-value observer twice.

- (id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        [self initialize];
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        [self initialize];
    }
    return self;
}

- (void)dealloc
{
    [self closeAutoCompleteCollectionView];
    [self stopObservingKeyPathsAndNotifications];
}

- (void)initialize
{
    [self beginObservingKeyPathsAndNotifications];
    [self setDefaultValuesForVariables];

    UICollectionView *newCollectionView = [[self class] newAutoCompleteCollectionViewForTextField:self];
    [self setAutoCompleteCollectionView:newCollectionView];
    [self registerAutoCompleteCellClass:[MLPAutoCompleteCell class] forCellReuseIdentifier:kDefaultAutoCompleteCellIdentifier];
    [self styleAutoCompleteViewForBorderStyle:self.borderStyle];
}

#pragma mark - Notifications and Key-Value Observing

- (void)beginObservingKeyPathsAndNotifications
{
    [self addObserver:self forKeyPath:kBorderStyleKeyPath options:NSKeyValueObservingOptionNew context:nil];
    [self addObserver:self forKeyPath:kAutoCompleteCollectionViewHiddenKeyPath options:NSKeyValueObservingOptionNew context:nil];
    [self addObserver:self forKeyPath:kBackgroundColorKeyPath options:NSKeyValueObservingOptionNew context:nil];
    [self addObserver:self forKeyPath:kKeyboardAccessoryInputKeyPath options:NSKeyValueObservingOptionNew context:nil];
    [self addObserver:self forKeyPath:kMaximumNumberOfAutoCompleteRowsKeyPath options:NSKeyValueObservingOptionNew context:nil];
    [self addObserver:self forKeyPath:kAutoCompleteScrollDirectionKeyPath options:NSKeyValueObservingOptionNew context:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(textFieldDidChangeWithNotification:)
        name:UITextFieldTextDidChangeNotification object:self];
}

- (void)stopObservingKeyPathsAndNotifications
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [self removeObserver:self forKeyPath:kBorderStyleKeyPath];
    [self removeObserver:self forKeyPath:kAutoCompleteCollectionViewHiddenKeyPath];
    [self removeObserver:self forKeyPath:kBackgroundColorKeyPath];
    [self removeObserver:self forKeyPath:kKeyboardAccessoryInputKeyPath];
    [self removeObserver:self forKeyPath:kMaximumNumberOfAutoCompleteRowsKeyPath];
    [self removeObserver:self forKeyPath:kAutoCompleteScrollDirectionKeyPath];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if([keyPath isEqualToString:kBorderStyleKeyPath]) {
        [self styleAutoCompleteViewForBorderStyle:self.borderStyle];
    }
    else if ([keyPath isEqualToString:kAutoCompleteCollectionViewHiddenKeyPath]) {
        if(self.autoCompleteCollectionView.hidden) {
            // Do not call closeAutoCompleteCollectionView here because keyboard accessory is shown only when the control becomes
            // first responder. This is needed so that we can hide/shown the table view from the superview during orientation changes.
            self.autoCompleteCollectionView.alpha = 0;
        }
        else {
            [self setAutoCompleteViewAppearance];
            NSInteger numberOfRows = [self.autoCompleteSuggestions count];
            [self expandAutoCompleteCollectionViewForNumberOfRows:numberOfRows];
            [self.autoCompleteCollectionView reloadData];
        }
    }
    else if ([keyPath isEqualToString:kBackgroundColorKeyPath]) {
        [self styleAutoCompleteViewForBorderStyle:self.borderStyle];
    }
    else if ([keyPath isEqualToString:kKeyboardAccessoryInputKeyPath] ||
        [keyPath isEqualToString:kMaximumNumberOfAutoCompleteRowsKeyPath]) {
        [self setAutoCompleteViewAppearance];
    }
    else if ([keyPath isEqualToString:kAutoCompleteScrollDirectionKeyPath]) {
        [self updateCollectionViewLayout];
    }
}

#pragma mark - UICollectionViewDataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    NSInteger numberOfRows = [self.autoCompleteSuggestions count];
    [self expandAutoCompleteCollectionViewForNumberOfRows:numberOfRows];
    return numberOfRows;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    NSString *cellIdentifier = self.reuseIdentifier ? self.reuseIdentifier : kDefaultAutoCompleteCellIdentifier;
    MLPAutoCompleteCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:cellIdentifier forIndexPath:indexPath];

    NSString *suggestedString = [self suggestedStringAtIndexPath:indexPath];
    [self configureCell:cell atIndexPath:indexPath withAutoCompleteString:suggestedString];

    return cell;
}

- (void)configureCell:(MLPAutoCompleteCell *)cell atIndexPath:(NSIndexPath *)indexPath withAutoCompleteString:(NSString *)string
{
    NSAttributedString *boldedString = nil;

    if(self.applyBoldEffectToAutoCompleteSuggestions) {
        boldedString = [self boldedString:string withSubstrings:self.text
            separatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }

    id autoCompleteObject = self.autoCompleteSuggestions[indexPath.row];

    if(![autoCompleteObject conformsToProtocol:@protocol(MLPAutoCompletionObject)]) {
        autoCompleteObject = nil;
    }

    if([self.autoCompleteDelegate respondsToSelector:@selector(
        autoCompleteTextField:shouldConfigureCell:withAutoCompleteString:withAttributedString:forAutoCompleteObject:forRowAtIndexPath:)]) {

        if(![self.autoCompleteDelegate autoCompleteTextField:self shouldConfigureCell:cell withAutoCompleteString:string
            withAttributedString:boldedString forAutoCompleteObject:autoCompleteObject forRowAtIndexPath:indexPath]) {

            return;
        }
    }

    cell.textLabel.textAlignment = self.autoCompleteCellTextAlignment;
    cell.backgroundColor = self.autoCompleteCellBackgroundColor;
    cell.textLabel.textColor = self.textColor;

    if(boldedString) {
        [cell.textLabel setAttributedText:boldedString];
    }
    else {
        cell.textLabel.textColor = (self.autoCompleteCellTextColor != nil) ? self.autoCompleteCellTextColor : self.textColor;
        cell.textLabel.font = [UIFont fontWithName:self.font.fontName size:self.autoCompleteFontSize];
        cell.textLabel.text = string;
    }
}

#pragma mark - UICollectionViewDelegateFlowLayout

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout*)collectionViewLayout
    sizeForItemAtIndexPath:(NSIndexPath *)indexPath {

    if (self.autoCompleteScrollDirection == UICollectionViewScrollDirectionVertical) {
        return CGSizeMake(collectionView.frame.size.width, self.autoCompleteRowHeight);
    }
    else {
        if (self.sizingCollectionViewCell == nil) {
            CGRect frame = CGRectMake(0, 0, collectionView.frame.size.width, self.autoCompleteRowHeight);
            _sizingCollectionViewCell = [[MLPAutoCompleteCell alloc] initWithFrame:frame];
        }

        NSString *suggestedString = [self suggestedStringAtIndexPath:indexPath];

        // Note: Ideally, when calculating the width of the sizing cell, we'd want to call configureCell:atIndexPath:withAutoCompleteString:
        // to apply exactly the same bold attributes as the ones being displayed in the cell; however, this function is expensive because it
        // highlights substrings and there is no easy way to make it an order of magnitude faster. On the other hand, if you have hundreds
        // of auto complete suggestions, collectionView:layout:sizeForItemAtIndexPath: is going to be called hundreds of times.
        // So instead, we assume that the entire text is bold and use that as the approximation of the label width.

        self.sizingCollectionViewCell.textLabel.font = [UIFont fontWithName:self.autoCompleteBoldFontName size:self.autoCompleteFontSize];
        self.sizingCollectionViewCell.textLabel.text = suggestedString;

        CGSize size = [self.sizingCollectionViewCell sizeThatFits:CGSizeMake(DBL_MAX, self.autoCompleteRowHeight)];
        size = CGSizeMake(size.width, self.autoCompleteRowHeight);

        NSInteger numberOfRows = [self.autoCompleteSuggestions count];

        // Make it so that the last cell fills the width of the collectionView (so that the user can tap on the empty space to select it)

        if (indexPath.row == numberOfRows - 1) {
            CGFloat totalWidth = 0.f;
            for (int i=0; i < numberOfRows - 1; i++) {
                totalWidth += [self collectionView:collectionView layout:collectionViewLayout
                    sizeForItemAtIndexPath:[NSIndexPath indexPathForRow:i inSection:0]].width;

                if (totalWidth > collectionView.frame.size.width) break;
            }

            totalWidth += size.width;

            if (totalWidth < collectionView.frame.size.width) {
                size.width += (collectionView.frame.size.width - totalWidth);
            }
        }

        return size;
    }
}

#pragma mark - UICollectionViewDelegate

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    if(!self.autoCompleteAppearsAsKeyboardAccessory) {
        [self closeAutoCompleteCollectionView];
    }

    MLPAutoCompleteCell *selectedCell = (MLPAutoCompleteCell*)[collectionView cellForItemAtIndexPath:indexPath];
    NSString *autoCompleteString = selectedCell.textLabel.text;

    id autoCompleteSuggestion = self.autoCompleteSuggestions[indexPath.row];
    id<MLPAutoCompletionObject> autoCompleteObject = autoCompleteSuggestion;
    if(![autoCompleteObject conformsToProtocol:@protocol(MLPAutoCompletionObject)]) {
        autoCompleteObject = nil;
    }

    if([self.autoCompleteDelegate respondsToSelector:
        @selector(autoCompleteTextField:willSelectAutoCompleteString:withAutoCompleteObject:forRowAtIndexPath:)]) {

        [self.autoCompleteDelegate autoCompleteTextField:self willSelectAutoCompleteString:autoCompleteString
            withAutoCompleteObject:autoCompleteObject forRowAtIndexPath:indexPath];
    }

    if (autoCompleteSuggestion != self.autoCompleteMenuItem && self.disableAutoCompleteReplacement == NO) {
        self.text = autoCompleteString;
    }
    
    if([self.autoCompleteDelegate respondsToSelector:
        @selector(autoCompleteTextField:didSelectAutoCompleteString:withAutoCompleteObject:forRowAtIndexPath:)]) {

        [self.autoCompleteDelegate autoCompleteTextField:self didSelectAutoCompleteString:autoCompleteString
            withAutoCompleteObject:autoCompleteObject forRowAtIndexPath:indexPath];
    }

    [self finishedSearching];
}

#pragma mark - MLPAutoCompleteSortOperationDelegate

- (void)autoCompleteTermsDidSort:(NSArray *)completions
{
    if (self.autoCompleteMenuItem) {
        completions = [completions arrayByAddingObject:self.autoCompleteMenuItem];
    }

    [self setAutoCompleteSuggestions:completions];
    [self.autoCompleteCollectionView reloadData];
    [self resetKeyboardAutoCompleteViewFrameForNumberOfRows:MIN(completions.count, self.maximumNumberOfAutoCompleteRows)];

    self.autoCompleteCollectionView.userInteractionEnabled = (self.autoCompleteSuggestions.count > 0);

    if (self.autoCompleteSuggestions.count > 0) {
        [self.autoCompleteCollectionView scrollToItemAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]
            atScrollPosition:UICollectionViewScrollPositionTop animated:YES];
    }
}

#pragma mark - MLPAutoCompleteFetchOperationDelegate

- (void)autoCompleteTermsDidFetch:(NSDictionary *)fetchInfo
{
    NSString *inputString = fetchInfo[kFetchedStringKey];
    NSArray *completions = fetchInfo[kFetchedTermsKey];

    [self.autoCompleteSortQueue cancelAllOperations];

    if(self.sortAutoCompleteSuggestionsByClosestMatch) {
        MLPAutoCompleteSortOperation *operation = [[MLPAutoCompleteSortOperation alloc] initWithDelegate:self
            incompleteString:inputString possibleCompletions:completions];

        [self.autoCompleteSortQueue addOperation:operation];
    }
    else {
        [self autoCompleteTermsDidSort:completions];
    }
}

#pragma mark - Events

- (void)setText:(NSString *)text
{
    [super setText:text];
    [self textFieldDidChangeWithNotification:nil];
}

- (void)textFieldDidChangeWithNotification:(NSNotification *)aNotification
{
    if(aNotification == nil || aNotification.object == self) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fetchAutoCompleteSuggestions) object:nil];
        [self performSelector:@selector(fetchAutoCompleteSuggestions) withObject:nil afterDelay:self.autoCompleteFetchRequestDelay];
    }
}

- (BOOL)becomeFirstResponder
{
    [self saveCurrentShadowProperties];

    if(self.showAutoCompleteWhenEditingBegins || self.autoCompleteAppearsAsKeyboardAccessory) {
        [self fetchAutoCompleteSuggestions];
    }

    return [super becomeFirstResponder];
}

- (void)finishedSearching
{
    [self resignFirstResponder];
}

- (BOOL)resignFirstResponder
{
    [self restoreOriginalShadowProperties];

    if(!self.autoCompleteAppearsAsKeyboardAccessory) {
        [self closeAutoCompleteCollectionView];
    }

    return [super resignFirstResponder];
}

#pragma mark - Open/Close Actions

- (void)expandAutoCompleteCollectionViewForNumberOfRows:(NSInteger)numberOfRows
{
    NSAssert(numberOfRows >= 0, @"Number of rows given for auto complete table was negative, this is impossible.");

    if(!self.isFirstResponder) {
        return;
    }

    if(self.autoCompleteAppearsAsKeyboardAccessory) {
        [self expandKeyboardAutoCompleteViewForNumberOfRows:numberOfRows];
    }
    else {
        [self expandDropDownAutoCompleteViewForNumberOfRows:numberOfRows];
    }
}

- (void)expandKeyboardAutoCompleteViewForNumberOfRows:(NSInteger)numberOfRows
{
    if(numberOfRows && (self.autoCompleteViewHidden == NO)) {
        [self.autoCompleteCollectionView setAlpha:1];
    }
    else {
        [self.autoCompleteCollectionView setAlpha:0];
    }
}

- (void)expandDropDownAutoCompleteViewForNumberOfRows:(NSInteger)numberOfRows
{
    [self resetDropDownAutoCompleteViewFrameForNumberOfRows:numberOfRows];

    if(numberOfRows && (self.autoCompleteViewHidden == NO)) {
        [self.autoCompleteCollectionView setAlpha:1];

        if(!self.autoCompleteCollectionView.superview) {
            if([self.autoCompleteDelegate respondsToSelector:@selector(autoCompleteTextField:willShowAutoCompleteCollectionView:)]) {
                [self.autoCompleteDelegate autoCompleteTextField:self willShowAutoCompleteCollectionView:self.autoCompleteCollectionView];
            }
        }

        [self.superview bringSubviewToFront:self];
        [self.superview insertSubview:self.autoCompleteCollectionView belowSubview:self];
        [self.autoCompleteCollectionView setUserInteractionEnabled:YES];

        if(self.showTextFieldDropShadowWhenAutoCompleteIsOpen) {
            [self.layer setShadowColor:[[UIColor blackColor] CGColor]];
            [self.layer setShadowOffset:CGSizeMake(0, 1)];
            [self.layer setShadowOpacity:0.35];
        }
    }
    else {
        [self closeAutoCompleteCollectionView];
        [self restoreOriginalShadowProperties];
        [self.autoCompleteCollectionView.layer setShadowOpacity:0.0];
    }
}

- (void)closeAutoCompleteCollectionView
{
    // The if statement here is a workaround for possible UIKit bug.
    // When hardware keyabord is connected (or possibly a bluetooth
    // keyboard) after dealloc of this object the keyboard appears if
    // `removeFromSuperview` is called. and then it's possible to tap
    // on any button on the keyboard and the app crashes.
    if (self.superview) {
        [self.autoCompleteCollectionView removeFromSuperview];
    }

    [self setInputAccessoryView:nil];
    [self restoreOriginalShadowProperties];
}

#pragma mark - Setters

- (void)setDefaultValuesForVariables
{
    [self setClipsToBounds:NO];
    [self setAutoCompleteFetchRequestDelay:kDefaultAutoCompleteRequestDelay];
    [self setSortAutoCompleteSuggestionsByClosestMatch:YES];
    [self setApplyBoldEffectToAutoCompleteSuggestions:YES];
    [self setShowTextFieldDropShadowWhenAutoCompleteIsOpen:YES];
    [self setAutoCompleteRowHeight:40];
    [self setAutoCompleteFontSize:14];
    [self setMaximumNumberOfAutoCompleteRows:3];
    [self setAutoCompleteScrollDirection:UICollectionViewScrollDirectionVertical];

    [self setAutoCompleteCellBackgroundColor:[UIColor clearColor]];

    UIFont *regularFont = [UIFont systemFontOfSize:13];
    [self setAutoCompleteRegularFontName:regularFont.fontName];

    UIFont *boldFont = [UIFont boldSystemFontOfSize:13];
    [self setAutoCompleteBoldFontName:boldFont.fontName];

    [self setAutoCompleteSuggestions:[NSMutableArray array]];

    [self setAutoCompleteSortQueue:[NSOperationQueue new]];
    self.autoCompleteSortQueue.name = [NSString stringWithFormat:@"Autocomplete Queue %i", arc4random()];

    [self setAutoCompleteFetchQueue:[NSOperationQueue new]];
    self.autoCompleteFetchQueue.name = [NSString stringWithFormat:@"Fetch Queue %i", arc4random()];

    self.autoCompleteCellTextAlignment = NSTextAlignmentLeft;
    self.autocorrectionType = UITextAutocorrectionTypeNo;
}

- (void)setAutoCompleteViewAppearance
{
    if(self.autoCompleteAppearsAsKeyboardAccessory) {
        [self setAutoCompleteViewForKeyboardAppearance];
    }
    else {
        [self setAutoCompleteViewForDropDownAppearance];
    }
}

- (void)setAutoCompleteViewForKeyboardAppearance
{
    [self resetKeyboardAutoCompleteViewFrameForNumberOfRows:MIN(self.autoCompleteSuggestions.count, self.maximumNumberOfAutoCompleteRows)];
    if (UIEdgeInsetsEqualToEdgeInsets(self.autoCompleteContentInsets, self.autoCompleteCollectionView.contentInset) == NO) {
        // The if check fixes UIViewAlertForUnsatisfiableConstraints when you rotate the device after
        // choosing an item from suggestions and rotating the device.
        self.autoCompleteCollectionView.contentInset = self.autoCompleteContentInsets;
    }
    [self.autoCompleteCollectionView setScrollIndicatorInsets:self.autoCompleteScrollIndicatorInsets];
    [self setInputAccessoryView:self.autoCompleteCollectionView];
}

- (void)setAutoCompleteViewForDropDownAppearance
{
    [self resetDropDownAutoCompleteViewFrameForNumberOfRows:self.maximumNumberOfAutoCompleteRows];
    [self.autoCompleteCollectionView setContentInset:self.autoCompleteContentInsets];
    [self.autoCompleteCollectionView setScrollIndicatorInsets:self.autoCompleteScrollIndicatorInsets];
    [self setInputAccessoryView:nil];
}

- (void)setAutoCompleteViewHidden:(BOOL)autoCompleteCollectionViewHidden
{
    [self.autoCompleteCollectionView setHidden:autoCompleteCollectionViewHidden];
}

- (void)setAutoCompleteBackgroundColor:(UIColor *)autoCompleteBackgroundColor
{
    [self.autoCompleteCollectionView setBackgroundColor:autoCompleteBackgroundColor];
    _autoCompleteBackgroundColor = autoCompleteBackgroundColor;
}

- (void)setAutoCompleteBorderWidth:(CGFloat)autoCompleteBorderWidth
{
    [self.autoCompleteCollectionView.layer setBorderWidth:autoCompleteBorderWidth];
    _autoCompleteBorderWidth = autoCompleteBorderWidth;
}

- (void)setAutoCompleteBorderColor:(UIColor *)autoCompleteBorderColor
{
    [self.autoCompleteCollectionView.layer setBorderColor:[autoCompleteBorderColor CGColor]];
    _autoCompleteBorderColor = autoCompleteBorderColor;
}

- (void)setAutoCompleteContentInsets:(UIEdgeInsets)autoCompleteContentInsets
{
    [self.autoCompleteCollectionView setContentInset:autoCompleteContentInsets];
    _autoCompleteContentInsets = autoCompleteContentInsets;
}

- (void)setAutoCompleteScrollIndicatorInsets:(UIEdgeInsets)autoCompleteScrollIndicatorInsets
{
    [self.autoCompleteCollectionView setScrollIndicatorInsets:autoCompleteScrollIndicatorInsets];
    _autoCompleteScrollIndicatorInsets = autoCompleteScrollIndicatorInsets;
}

- (void)resetKeyboardAutoCompleteViewFrameForNumberOfRows:(NSInteger)numberOfRows
{
    [self.autoCompleteCollectionView.layer setCornerRadius:0];

    CGRect newAutoCompleteCollectionViewFrame =
        [[self class] autoCompleteCollectionViewFrameForTextField:self forNumberOfRows:numberOfRows];

    [self.autoCompleteCollectionView setFrame:newAutoCompleteCollectionViewFrame];

    [self.autoCompleteCollectionView setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
    [self.autoCompleteCollectionView scrollRectToVisible:CGRectMake(0, 0, 1, 1) animated:NO];
}

- (void)resetDropDownAutoCompleteViewFrameForNumberOfRows:(NSInteger)numberOfRows
{
    [self.autoCompleteCollectionView.layer setCornerRadius:self.autoCompleteCornerRadius];

    CGRect newAutoCompleteCollectionViewFrame =
        [[self class] autoCompleteCollectionViewFrameForTextField:self forNumberOfRows:numberOfRows];

    [self.autoCompleteCollectionView setFrame:newAutoCompleteCollectionViewFrame];
    [self.autoCompleteCollectionView scrollRectToVisible:CGRectMake(0, 0, 1, 1) animated:NO];
}

- (void)registerAutoCompleteCellNib:(UINib *)nib forCellReuseIdentifier:(NSString *)reuseIdentifier
{
    NSAssert(self.autoCompleteCollectionView, @"Must have an autoCompleteCollectionView to register cells to.");

    if(self.reuseIdentifier) {
        [self unregisterAutoCompleteCellForReuseIdentifier:self.reuseIdentifier];
    }

    [self.autoCompleteCollectionView registerNib:nib forCellWithReuseIdentifier:reuseIdentifier];
    [self setReuseIdentifier:reuseIdentifier];
}

- (void)registerAutoCompleteCellClass:(Class)cellClass forCellReuseIdentifier:(NSString *)reuseIdentifier
{
    NSAssert(self.autoCompleteCollectionView, @"Must have an autoCompleteCollectionView to register cells to.");

    if(self.reuseIdentifier) {
        [self unregisterAutoCompleteCellForReuseIdentifier:self.reuseIdentifier];
    }

    [self.autoCompleteCollectionView registerClass:cellClass forCellWithReuseIdentifier:reuseIdentifier];
    [self setReuseIdentifier:reuseIdentifier];
}

- (void)unregisterAutoCompleteCellForReuseIdentifier:(NSString *)reuseIdentifier
{
    [self.autoCompleteCollectionView registerNib:nil forCellWithReuseIdentifier:reuseIdentifier];
}

- (void)styleAutoCompleteViewForBorderStyle:(UITextBorderStyle)borderStyle
{
    if([self.autoCompleteDelegate respondsToSelector:
        @selector(autoCompleteTextField:shouldStyleAutoCompleteCollectionView:forBorderStyle:)]) {

        if(![self.autoCompleteDelegate autoCompleteTextField:self
            shouldStyleAutoCompleteCollectionView:self.autoCompleteCollectionView forBorderStyle:borderStyle]) {

            return;
        }
    }

    switch (borderStyle) {
        case UITextBorderStyleRoundedRect:
            [self setRoundedRectStyleForAutoCompleteCollectionView];
            break;

        case UITextBorderStyleBezel:
        case UITextBorderStyleLine:
            [self setLineStyleForAutoCompleteCollectionView];
            break;

        case UITextBorderStyleNone:
            [self setNoneStyleForAutoCompleteCollectionView];
            break;

        default:
            break;
    }
}

- (void)setRoundedRectStyleForAutoCompleteCollectionView
{
    [self setAutoCompleteCornerRadius:8.0];
    [self setAutoCompleteOriginOffset:CGSizeMake(0, -18)];
    [self setAutoCompleteScrollIndicatorInsets:UIEdgeInsetsMake(18, 0, 0, 0)];
    [self setAutoCompleteContentInsets:UIEdgeInsetsMake(18, 0, 0, 0)];

    if(self.backgroundColor == [UIColor clearColor]) {
        [self setAutoCompleteBackgroundColor:[UIColor whiteColor]];
    }
    else {
        [self setAutoCompleteBackgroundColor:self.backgroundColor];
    }
}

- (void)setLineStyleForAutoCompleteCollectionView
{
    [self setAutoCompleteCornerRadius:0.0];
    [self setAutoCompleteOriginOffset:CGSizeZero];
    [self setAutoCompleteScrollIndicatorInsets:UIEdgeInsetsZero];
    [self setAutoCompleteContentInsets:UIEdgeInsetsZero];
    [self setAutoCompleteBorderWidth:1.0];
    [self setAutoCompleteBorderColor:[UIColor colorWithWhite:0.0 alpha:0.5]];

    if(self.backgroundColor == [UIColor clearColor]) {
        [self setAutoCompleteBackgroundColor:[UIColor whiteColor]];
    }
    else {
        [self setAutoCompleteBackgroundColor:self.backgroundColor];
    }
}

- (void)setNoneStyleForAutoCompleteCollectionView
{
    [self setAutoCompleteCornerRadius:8.0];
    [self setAutoCompleteOriginOffset:CGSizeMake(0, 7)];
    [self setAutoCompleteScrollIndicatorInsets:UIEdgeInsetsZero];
    [self setAutoCompleteContentInsets:UIEdgeInsetsZero];
    [self setAutoCompleteBorderWidth:1.0];

    UIColor *lightBlueColor = [UIColor colorWithRed:181/255.0 green:204/255.0 blue:255/255.0 alpha:1.0];
    [self setAutoCompleteBorderColor:lightBlueColor];

    UIColor *blueTextColor = [UIColor colorWithRed:23/255.0 green:119/255.0 blue:206/255.0 alpha:1.0];
    [self setAutoCompleteCellTextColor:blueTextColor];

    if(self.backgroundColor == [UIColor clearColor]) {
        [self setAutoCompleteBackgroundColor:[UIColor whiteColor]];
    }
    else {
        [self setAutoCompleteBackgroundColor:self.backgroundColor];
    }
}

- (void)saveCurrentShadowProperties
{
    [self setOriginalShadowColor:self.layer.shadowColor];
    [self setOriginalShadowOffset:self.layer.shadowOffset];
    [self setOriginalShadowOpacity:self.layer.shadowOpacity];
}

- (void)restoreOriginalShadowProperties
{
    [self.layer setShadowColor:self.originalShadowColor];
    [self.layer setShadowOffset:self.originalShadowOffset];
    [self.layer setShadowOpacity:self.originalShadowOpacity];
}

- (void)updateCollectionViewLayout
{
    UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout*)self.autoCompleteCollectionView.collectionViewLayout;
    layout.scrollDirection = self.autoCompleteScrollDirection;
    layout.minimumInteritemSpacing = 0;
}

#pragma mark - Getters

- (BOOL)autoCompleteViewHidden
{
    return self.autoCompleteCollectionView.hidden;
}

- (NSString *)suggestedStringAtIndexPath:(NSIndexPath *)indexPath
{
    NSString *suggestedString;
    id autoCompleteObject = self.autoCompleteSuggestions[indexPath.row];

    if([autoCompleteObject isKindOfClass:[NSString class]]) {
        suggestedString = (NSString *)autoCompleteObject;
    }
    else if ([autoCompleteObject conformsToProtocol:@protocol(MLPAutoCompletionObject)]) {
        suggestedString = [(id <MLPAutoCompletionObject>)autoCompleteObject autocompleteString];
    }
    else {
        NSAssert(0, @"Autocomplete suggestions must either be NSString or objects conforming to the MLPAutoCompletionObject protocol.");
    }

    return suggestedString;
}

- (void)fetchAutoCompleteSuggestions
{
    if(self.disableAutoCompleteUserInteractionWhileFetching) {
        [self.autoCompleteCollectionView setUserInteractionEnabled:NO];
    }

    [self.autoCompleteFetchQueue cancelAllOperations];

    MLPAutoCompleteFetchOperation *fetchOperation = [[MLPAutoCompleteFetchOperation alloc]
        initWithDelegate:self completionsDataSource:self.autoCompleteDataSource autoCompleteTextField:self];

    [self.autoCompleteFetchQueue addOperation:fetchOperation];
}

#pragma mark - Factory Methods

+ (UICollectionView *)newAutoCompleteCollectionViewForTextField:(MLPAutoCompleteTextField *)textField
{
    CGRect frame = [[self class] autoCompleteCollectionViewFrameForTextField:textField];
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection = UICollectionViewScrollDirectionVertical;
    layout.minimumInteritemSpacing = 0;
    layout.minimumLineSpacing = 0;

    UICollectionView *collectionView = [[UICollectionView alloc] initWithFrame:frame collectionViewLayout:layout];
    collectionView.dataSource = textField;
    collectionView.delegate = textField;

    return collectionView;
}

+ (CGRect)autoCompleteCollectionViewFrameForTextField:(MLPAutoCompleteTextField *)textField forNumberOfRows:(NSInteger)numberOfRows
{
    CGRect newCollectionViewFrame = CGRectZero;
    CGFloat height = [[self class] autoCompleteViewHeightForTextField:textField withNumberOfRows:numberOfRows];

    if(textField.autoCompleteAppearsAsKeyboardAccessory) {
        CGSize screenSize = [UIScreen mainScreen].bounds.size;
        UIInterfaceOrientation orientation = [[UIApplication sharedApplication] statusBarOrientation];
        newCollectionViewFrame.size.width = screenSize.width;

        if (textField.autoCompleteScrollDirection == UICollectionViewScrollDirectionVertical) {
            newCollectionViewFrame.size.height = height;
        }
        else {
            newCollectionViewFrame.size.height = (numberOfRows == 0 ? 0 : textField.autoCompleteRowHeight);
        }

        newCollectionViewFrame.origin.y = -CGRectGetHeight(newCollectionViewFrame);
    }
    else {
        newCollectionViewFrame = [[self class] autoCompleteCollectionViewFrameForTextField:textField];
        newCollectionViewFrame.size.height = height + textField.autoCompleteCollectionView.contentInset.top;
    }

    return newCollectionViewFrame;
}

+ (CGFloat)autoCompleteViewHeightForTextField:(MLPAutoCompleteTextField *)textField withNumberOfRows:(NSInteger)numberOfRows
{
    CGFloat maximumHeightMultiplier = (textField.maximumNumberOfAutoCompleteRows - 0.5);
    CGFloat heightMultiplier;

    if(numberOfRows >= textField.maximumNumberOfAutoCompleteRows) {
        heightMultiplier = maximumHeightMultiplier;
    }
    else {
        heightMultiplier = numberOfRows;
    }

    CGFloat height = textField.autoCompleteRowHeight * heightMultiplier;
    return height;
}

+ (CGRect)autoCompleteCollectionViewFrameForTextField:(MLPAutoCompleteTextField *)textField
{
    CGRect frame = textField.frame;
    if (CGRectIsEmpty(frame)) return frame;

    frame.origin.y += textField.frame.size.height;
    frame.origin.x += textField.autoCompleteOriginOffset.width;
    frame.origin.y += textField.autoCompleteOriginOffset.height;
    frame = CGRectInset(frame, 1, 0);

    return frame;
}

- (NSAttributedString *)boldedString:(NSString *)string withSubstrings:(NSString *)substrings
    separatedByCharactersInSet:(NSCharacterSet *)characterSet
{
    UIFont *boldFont = [UIFont fontWithName:self.autoCompleteBoldFontName size:self.autoCompleteFontSize];
    UIFont *regularFont = [UIFont fontWithName:self.autoCompleteRegularFontName size:self.autoCompleteFontSize];

    UIColor *boldTextColor = [UIColor darkTextColor];
    UIColor *regularTextColor = [UIColor darkTextColor];

    if (self.autoCompleteCellBoldTextColor) {
      boldTextColor = self.autoCompleteCellBoldTextColor;
    }

    if (self.autoCompleteCellTextColor) {
      regularTextColor = self.autoCompleteCellTextColor;
    }

    NSDictionary *boldTextAttributes = @{NSFontAttributeName : boldFont, NSForegroundColorAttributeName : boldTextColor};
    NSDictionary *regularTextAttributes = @{NSFontAttributeName : regularFont, NSForegroundColorAttributeName : regularTextColor};
    NSDictionary *firstAttributes;
    NSDictionary *secondAttributes;

    if(self.reverseAutoCompleteSuggestionsBoldEffect) {
        firstAttributes = regularTextAttributes;
        secondAttributes = boldTextAttributes;
    }
    else {
        firstAttributes = boldTextAttributes;
        secondAttributes = regularTextAttributes;
    }

    NSMutableAttributedString *attributedText = [[NSMutableAttributedString alloc] initWithString:string attributes:firstAttributes];

    substrings = [substrings stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSArray *components = [substrings componentsSeparatedByCharactersInSet:characterSet];

    for (NSString *component in components) {
        NSRange range = NSMakeRange(0, string.length);
        while(range.location != NSNotFound) {
            range = [string rangeOfString:component options:NSCaseInsensitiveSearch range:range];
            if (range.location != NSNotFound) {
                [attributedText setAttributes:secondAttributes range:range];
                range = NSMakeRange(range.location + range.length, string.length - (range.location + range.length));
            }
        }
    }

    return attributedText;
}

@end

#pragma mark - MLPAutoCompleteFetchOperation

@implementation MLPAutoCompleteFetchOperation

- (void)main
{
    @autoreleasepool {
        if (self.isCancelled) {
            return;
        }

        if([self.dataSource respondsToSelector:@selector(autoCompleteTextField:possibleCompletionsForString:completionHandler:)]) {
            __block BOOL waitingForSuggestions = YES;
            __weak MLPAutoCompleteFetchOperation *operation = self;

            [self.dataSource autoCompleteTextField:self.textField possibleCompletionsForString:self.incompleteString
                completionHandler:^(NSArray *suggestions) {

                [operation performSelector:@selector(didReceiveSuggestions:) withObject:suggestions];
                waitingForSuggestions = NO;
            }];

            while(waitingForSuggestions) {
                [NSThread sleepForTimeInterval:250];

                if(self.isCancelled) {
                    return;
                }
            }

        } else if ([self.dataSource respondsToSelector:@selector(autoCompleteTextField:possibleCompletionsForString:)]) {
            NSArray *results = [self.dataSource autoCompleteTextField:self.textField possibleCompletionsForString:self.incompleteString];

            if(!self.isCancelled) {
                [self didReceiveSuggestions:results];
            }

        } else {
            NSAssert(0, @"An autocomplete datasource must implement either autoCompleteTextField:possibleCompletionsForString: or "
                "autoCompleteTextField:possibleCompletionsForString:completionHandler:");
        }
    }
}

- (void)didReceiveSuggestions:(NSArray *)suggestions
{
    if(suggestions == nil) {
        suggestions = [NSArray array];
    }

    if(!self.isCancelled) {
        if(suggestions.count) {
            NSObject *firstObject = suggestions[0];
            NSAssert([firstObject isKindOfClass:[NSString class]] || [firstObject conformsToProtocol:@protocol(MLPAutoCompletionObject)],
                @"MLPAutoCompleteTextField expects an array with objects that are either strings or conform to the MLPAutoCompletionObject "
                "protocol for possible completions.");
        }

        NSDictionary *resultsInfo = @{kFetchedTermsKey: suggestions, kFetchedStringKey : self.incompleteString};

        [(NSObject *)self.delegate performSelectorOnMainThread:@selector(autoCompleteTermsDidFetch:)
            withObject:resultsInfo waitUntilDone:NO];
    };
}

- (id)initWithDelegate:(id<MLPAutoCompleteFetchOperationDelegate>)aDelegate
    completionsDataSource:(id<MLPAutoCompleteTextFieldDataSource>)aDataSource autoCompleteTextField:(MLPAutoCompleteTextField *)aTextField
{
    self = [super init];
    if (self) {
        [self setDelegate:aDelegate];
        [self setTextField:aTextField];
        [self setDataSource:aDataSource];
        [self setIncompleteString:aTextField.text];

        if(!self.incompleteString) {
            self.incompleteString = @"";
        }
    }
    return self;
}

- (void)dealloc
{
    [self setDelegate:nil];
    [self setTextField:nil];
    [self setDataSource:nil];
    [self setIncompleteString:nil];
}
@end

#pragma mark - MLPAutoCompleteSortOperation

@implementation MLPAutoCompleteSortOperation

- (void)main
{
    @autoreleasepool {
        if (self.isCancelled) {
            return;
        }

        NSArray *results = [self sortedCompletionsForString:self.incompleteString withPossibleStrings:self.possibleCompletions];

        if (self.isCancelled) {
            return;
        }

        if(!self.isCancelled) {
            [(NSObject*)self.delegate performSelectorOnMainThread:@selector(autoCompleteTermsDidSort:) withObject:results waitUntilDone:NO];
        }
    }
}

- (id)initWithDelegate:(id<MLPAutoCompleteSortOperationDelegate>)aDelegate incompleteString:(NSString *)string
    possibleCompletions:(NSArray *)possibleStrings
{
    self = [super init];
    if (self) {
        [self setDelegate:aDelegate];
        [self setIncompleteString:string];
        [self setPossibleCompletions:possibleStrings];
    }
    return self;
}

- (NSArray *)sortedCompletionsForString:(NSString *)inputString withPossibleStrings:(NSArray *)possibleTerms
{
    if([inputString isEqualToString:@""]) {
        return possibleTerms;
    }

    if(self.isCancelled) {
        return [NSArray array];
    }

    NSMutableArray *editDistances = [NSMutableArray arrayWithCapacity:possibleTerms.count];

    for(NSObject *originalObject in possibleTerms) {
        NSString *currentString;

        if([originalObject isKindOfClass:[NSString class]]) {
            currentString = (NSString *)originalObject;
        }
        else if ([originalObject conformsToProtocol:@protocol(MLPAutoCompletionObject)]) {
            currentString = [(id <MLPAutoCompletionObject>)originalObject autocompleteString];
        }
        else {
            NSAssert(0, @"Autocompletion terms must either be strings or objects conforming to the MLPAutoCompleteObject protocol.");
        }

        if(self.isCancelled) {
            return [NSArray array];
        }

        NSUInteger maximumRange = (inputString.length < currentString.length) ? inputString.length : currentString.length;

        float editDistanceOfCurrentString =
            [inputString asciiLevenshteinDistanceWithString:[currentString substringWithRange:NSMakeRange(0, maximumRange)]];

        NSDictionary * stringsWithEditDistances = @{
            kSortInputStringKey : currentString,
            kSortObjectKey : originalObject,
            kSortEditDistancesKey : [NSNumber numberWithFloat:editDistanceOfCurrentString]
        };

        [editDistances addObject:stringsWithEditDistances];
    }

    if(self.isCancelled) {
        return [NSArray array];
    }

    [editDistances sortUsingComparator:^(NSDictionary *string1Dictionary, NSDictionary *string2Dictionary) {
        return [string1Dictionary[kSortEditDistancesKey] compare:string2Dictionary[kSortEditDistancesKey]];
    }];

    NSMutableArray *prioritySuggestions = [NSMutableArray array];
    NSMutableArray *otherSuggestions = [NSMutableArray array];

    for(NSDictionary *stringsWithEditDistances in editDistances) {
        if(self.isCancelled) {
            return [NSArray array];
        }

        NSObject *autoCompleteObject = stringsWithEditDistances[kSortObjectKey];
        NSString *suggestedString = stringsWithEditDistances[kSortInputStringKey];

        NSArray *suggestedStringComponents = [suggestedString componentsSeparatedByString:@" "];
        BOOL suggestedStringDeservesPriority = NO;

        for(NSString *component in suggestedStringComponents) {
            NSRange occurrenceOfInputString = [[component lowercaseString] rangeOfString:[inputString lowercaseString]];

            if (occurrenceOfInputString.length != 0 && occurrenceOfInputString.location == 0) {
                suggestedStringDeservesPriority = YES;
                [prioritySuggestions addObject:autoCompleteObject];
                break;
            }

            if([inputString length] <= 1) {
                //if the input string is very short, don't check anymore components of the input string.
                break;
            }
        }

        if(!suggestedStringDeservesPriority) {
            [otherSuggestions addObject:autoCompleteObject];
        }
    }

    NSMutableArray *results = [NSMutableArray array];
    [results addObjectsFromArray:prioritySuggestions];
    [results addObjectsFromArray:otherSuggestions];

    return [NSArray arrayWithArray:results];
}

- (void)dealloc
{
    [self setDelegate:nil];
    [self setIncompleteString:nil];
    [self setPossibleCompletions:nil];
}
@end
