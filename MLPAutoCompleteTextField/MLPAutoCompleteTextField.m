/*
 //  MLPAutoCompleteTextField.m
 //
 //
 //  Created by Eddy Borja on 12/29/12.
 //  Copyright (c) 2013 Mainloop LLC. All rights reserved.

 Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

#import "MLPAutoCompleteTextField.h"
#import "MLPAutoCompletionObject.h"
#import "NSString+Levenshtein.h"
#import <QuartzCore/QuartzCore.h>

static NSString *kSortInputStringKey = @"sortInputString";
static NSString *kSortEditDistancesKey = @"editDistances";
static NSString *kSortObjectKey = @"sortObject";
static NSString *kKeyboardAccessoryInputKeyPath = @"autoCompleteAppearsAsKeyboardAccessory";
const NSTimeInterval DefaultAutoCompleteRequestDelay = 0.1;

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


static NSString *kBorderStyleKeyPath = @"borderStyle";
static NSString *kAutoCompleteCollectionViewHiddenKeyPath = @"autoCompleteCollectionView.hidden";
static NSString *kBackgroundColorKeyPath = @"backgroundColor";
static NSString *kDefaultAutoCompleteCellIdentifier = @"_DefaultAutoCompleteCellIdentifier";
static NSString *kMaximumNumberOfAutoCompleteRowsKeyPath = @"maximumNumberOfAutoCompleteRows";

@interface MLPAutoCompleteTextField ()
@property (strong, readwrite) UITableView *autoCompleteCollectionView;
@property (strong) NSArray *autoCompleteSuggestions;
@property (strong) NSOperationQueue *autoCompleteSortQueue;
@property (strong) NSOperationQueue *autoCompleteFetchQueue;
@property (strong) NSString *reuseIdentifier;
@property (assign) CGColorRef originalShadowColor;
@property (assign) CGSize originalShadowOffset;
@property (assign) CGFloat originalShadowOpacity;
@end


@implementation MLPAutoCompleteTextField

#pragma mark - Init

// Note: Since initWithFrame: is the designated initializer for UIView class, do not override the init method.
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

    UITableView *newCollectionView = [[self class] newAutoCompleteCollectionViewForTextField:self];
    [self setAutoCompleteCollectionView:newCollectionView];

    [self styleAutoCompleteViewForBorderStyle:self.borderStyle];
}

#pragma mark - Notifications and KVO

- (void)beginObservingKeyPathsAndNotifications
{
    [self addObserver:self forKeyPath:kBorderStyleKeyPath options:NSKeyValueObservingOptionNew context:nil];
    [self addObserver:self forKeyPath:kAutoCompleteCollectionViewHiddenKeyPath options:NSKeyValueObservingOptionNew context:nil];
    [self addObserver:self forKeyPath:kBackgroundColorKeyPath options:NSKeyValueObservingOptionNew context:nil];
    [self addObserver:self forKeyPath:kKeyboardAccessoryInputKeyPath options:NSKeyValueObservingOptionNew context:nil];
    [self addObserver:self forKeyPath:kMaximumNumberOfAutoCompleteRowsKeyPath options:NSKeyValueObservingOptionNew context:nil];

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
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if([keyPath isEqualToString:kBorderStyleKeyPath]) {
        [self styleAutoCompleteViewForBorderStyle:self.borderStyle];
    }
    else if ([keyPath isEqualToString:kAutoCompleteCollectionViewHiddenKeyPath]) {
        if(self.autoCompleteCollectionView.hidden){
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
    else if ([keyPath isEqualToString:kBackgroundColorKeyPath]){
        [self styleAutoCompleteViewForBorderStyle:self.borderStyle];
    }
    else if ([keyPath isEqualToString:kKeyboardAccessoryInputKeyPath] ||
        [keyPath isEqualToString:kMaximumNumberOfAutoCompleteRowsKeyPath]){
        [self setAutoCompleteViewAppearance];
    }
}

#pragma mark - TableView Datasource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    NSInteger numberOfRows = [self.autoCompleteSuggestions count];
    [self expandAutoCompleteCollectionViewForNumberOfRows:numberOfRows];
    return numberOfRows;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = nil;
    NSString *cellIdentifier = kDefaultAutoCompleteCellIdentifier;

    if(!self.reuseIdentifier){
        cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
        if (cell == nil) {
            cell = [self autoCompleteCollectionViewCellWithReuseIdentifier:cellIdentifier];
        }
    } else {
        cell = [tableView dequeueReusableCellWithIdentifier:self.reuseIdentifier];
    }
    NSAssert(cell, @"Unable to create cell for autocomplete table");

    id autoCompleteObject = self.autoCompleteSuggestions[indexPath.row];
    NSString *suggestedString;
    if([autoCompleteObject isKindOfClass:[NSString class]]){
        suggestedString = (NSString *)autoCompleteObject;
    } else if ([autoCompleteObject conformsToProtocol:@protocol(MLPAutoCompletionObject)]){
        suggestedString = [(id <MLPAutoCompletionObject>)autoCompleteObject autocompleteString];
    } else {
        NSAssert(0, @"Autocomplete suggestions must either be NSString or objects conforming to the MLPAutoCompletionObject protocol.");
    }

    [self configureCell:cell atIndexPath:indexPath withAutoCompleteString:suggestedString];

    return cell;
}

- (UITableViewCell *)autoCompleteCollectionViewCellWithReuseIdentifier:(NSString *)identifier
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    [cell setBackgroundColor:[UIColor clearColor]];
    [cell.textLabel setTextColor:self.textColor];
    [cell.textLabel setFont:self.font];
    return cell;
}

- (void)configureCell:(UITableViewCell *)cell atIndexPath:(NSIndexPath *)indexPath withAutoCompleteString:(NSString *)string
{
    NSAttributedString *boldedString = nil;
    if(self.applyBoldEffectToAutoCompleteSuggestions){
        BOOL attributedTextSupport = [cell.textLabel respondsToSelector:@selector(setAttributedText:)];
        NSAssert(attributedTextSupport, @"Attributed strings on UILabels are  not supported before iOS 6.0");
        boldedString = [self boldedString:string withSubstrings:self.text
            separatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }

    id autoCompleteObject = self.autoCompleteSuggestions[indexPath.row];
    if(![autoCompleteObject conformsToProtocol:@protocol(MLPAutoCompletionObject)]){
        autoCompleteObject = nil;
    }

    if([self.autoCompleteDelegate respondsToSelector:
        @selector(autoCompleteTextField:shouldConfigureCell:withAutoCompleteString:withAttributedString:forAutoCompleteObject:forRowAtIndexPath:)]) {

        if(![self.autoCompleteDelegate autoCompleteTextField:self shouldConfigureCell:cell withAutoCompleteString:string withAttributedString:boldedString forAutoCompleteObject:autoCompleteObject forRowAtIndexPath:indexPath]) {
            return;
        }
    }

    [cell.textLabel setTextColor:self.textColor];

    if(boldedString){
        if ([cell.textLabel respondsToSelector:@selector(setAttributedText:)]) {
            [cell.textLabel setAttributedText:boldedString];
        } else{
            [cell.textLabel setText:string];
            [cell.textLabel setFont:[UIFont fontWithName:self.font.fontName size:self.autoCompleteFontSize]];
        }

    } else {
        [cell.textLabel setText:string];
        [cell.textLabel setFont:[UIFont fontWithName:self.font.fontName size:self.autoCompleteFontSize]];
    }

    if(self.autoCompleteCellTextColor){
        [cell.textLabel setTextColor:self.autoCompleteCellTextColor];
    }
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    [cell setBackgroundColor:self.autoCompleteCellBackgroundColor];
}

#pragma mark - TableView Delegate

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return self.autoCompleteRowHeight;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if(!self.autoCompleteAppearsAsKeyboardAccessory){
        [self closeAutoCompleteCollectionView];
    }

    UITableViewCell *selectedCell = [tableView cellForRowAtIndexPath:indexPath];
    NSString *autoCompleteString = selectedCell.textLabel.text;
    self.text = autoCompleteString;

    id<MLPAutoCompletionObject> autoCompleteObject = self.autoCompleteSuggestions[indexPath.row];
    if(![autoCompleteObject conformsToProtocol:@protocol(MLPAutoCompletionObject)]){
        autoCompleteObject = nil;
    }

    if([self.autoCompleteDelegate respondsToSelector:
        @selector(autoCompleteTextField:didSelectAutoCompleteString:withAutoCompleteObject:forRowAtIndexPath:)]){

        [self.autoCompleteDelegate autoCompleteTextField:self didSelectAutoCompleteString:autoCompleteString
            withAutoCompleteObject:autoCompleteObject forRowAtIndexPath:indexPath];
    }

    [self finishedSearching];
}

#pragma mark - AutoComplete Sort Operation Delegate

- (void)autoCompleteTermsDidSort:(NSArray *)completions
{
    [self setAutoCompleteSuggestions:completions];
    [self resetKeyboardAutoCompleteViewFrameForNumberOfRows:MIN(completions.count, self.maximumNumberOfAutoCompleteRows)];
    [self.autoCompleteCollectionView reloadData];

    if (self.autoCompleteSuggestions.count > 0) {
        [self.autoCompleteCollectionView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0] atScrollPosition:UITableViewRowAnimationTop animated:YES];
    }
}

#pragma mark - AutoComplete Fetch Operation Delegate

- (void)autoCompleteTermsDidFetch:(NSDictionary *)fetchInfo
{
    NSString *inputString = fetchInfo[kFetchedStringKey];
    NSArray *completions = fetchInfo[kFetchedTermsKey];

    [self.autoCompleteSortQueue cancelAllOperations];

    if(self.sortAutoCompleteSuggestionsByClosestMatch){
        MLPAutoCompleteSortOperation *operation =
            [[MLPAutoCompleteSortOperation alloc] initWithDelegate:self incompleteString:inputString possibleCompletions:completions];
        [self.autoCompleteSortQueue addOperation:operation];
    } else {
        [self autoCompleteTermsDidSort:completions];
    }
}

#pragma mark - Events

- (void)textFieldDidChangeWithNotification:(NSNotification *)aNotification
{
    if(aNotification.object == self){
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fetchAutoCompleteSuggestions) object:nil];
        [self performSelector:@selector(fetchAutoCompleteSuggestions) withObject:nil afterDelay:self.autoCompleteFetchRequestDelay];
    }
}

- (BOOL)becomeFirstResponder
{
    [self saveCurrentShadowProperties];

    if(self.showAutoCompleteWhenEditingBegins ||
       self.autoCompleteAppearsAsKeyboardAccessory){
        [self fetchAutoCompleteSuggestions];
    }

    return [super becomeFirstResponder];
}

- (void) finishedSearching
{
    [self resignFirstResponder];
}

- (BOOL)resignFirstResponder
{
    [self restoreOriginalShadowProperties];
    if(!self.autoCompleteAppearsAsKeyboardAccessory){
        [self closeAutoCompleteCollectionView];
    }
    return [super resignFirstResponder];
}

#pragma mark - Open/Close Actions

- (void)expandAutoCompleteCollectionViewForNumberOfRows:(NSInteger)numberOfRows
{
    NSAssert(numberOfRows >= 0, @"Number of rows given for auto complete table was negative, this is impossible.");

    if(!self.isFirstResponder){
        return;
    }

    if(self.autoCompleteAppearsAsKeyboardAccessory){
        [self expandKeyboardAutoCompleteViewForNumberOfRows:numberOfRows];
    } else {
        [self expandDropDownAutoCompleteViewForNumberOfRows:numberOfRows];
    }
}

- (void)expandKeyboardAutoCompleteViewForNumberOfRows:(NSInteger)numberOfRows
{
    if(numberOfRows && (self.autoCompleteViewHidden == NO)){
        [self.autoCompleteCollectionView setAlpha:1];
    } else {
        [self.autoCompleteCollectionView setAlpha:0];
    }
}

- (void)expandDropDownAutoCompleteViewForNumberOfRows:(NSInteger)numberOfRows
{
    [self resetDropDownAutoCompleteViewFrameForNumberOfRows:numberOfRows];

    if(numberOfRows && (self.autoCompleteViewHidden == NO)){
        [self.autoCompleteCollectionView setAlpha:1];

        if(!self.autoCompleteCollectionView.superview){
            if([self.autoCompleteDelegate
                respondsToSelector:@selector(autoCompleteTextField:willShowAutoCompleteCollectionView:)]){
                [self.autoCompleteDelegate autoCompleteTextField:self willShowAutoCompleteCollectionView:self.autoCompleteCollectionView];
            }
        }

        [self.superview bringSubviewToFront:self];
        [self.superview insertSubview:self.autoCompleteCollectionView belowSubview:self];
        [self.autoCompleteCollectionView setUserInteractionEnabled:YES];
        if(self.showTextFieldDropShadowWhenAutoCompleteIsOpen){
            [self.layer setShadowColor:[[UIColor blackColor] CGColor]];
            [self.layer setShadowOffset:CGSizeMake(0, 1)];
            [self.layer setShadowOpacity:0.35];
        }
    } else {
        [self closeAutoCompleteCollectionView];
        [self restoreOriginalShadowProperties];
        [self.autoCompleteCollectionView.layer setShadowOpacity:0.0];
    }
}

- (void)closeAutoCompleteCollectionView
{
    [self.autoCompleteCollectionView removeFromSuperview];
    [self setInputAccessoryView:nil];
    [self restoreOriginalShadowProperties];
}

#pragma mark - Setters

- (void)setDefaultValuesForVariables
{
    [self setClipsToBounds:NO];
    [self setAutoCompleteFetchRequestDelay:DefaultAutoCompleteRequestDelay];
    [self setSortAutoCompleteSuggestionsByClosestMatch:YES];
    [self setApplyBoldEffectToAutoCompleteSuggestions:YES];
    [self setShowTextFieldDropShadowWhenAutoCompleteIsOpen:YES];
    [self setAutoCompleteRowHeight:40];
    [self setAutoCompleteFontSize:13];
    [self setMaximumNumberOfAutoCompleteRows:3];

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
}

- (void)setAutoCompleteViewAppearance
{
    if(self.autoCompleteAppearsAsKeyboardAccessory){
        [self setAutoCompleteViewForKeyboardAppearance];
    } else {
        [self setAutoCompleteViewForDropDownAppearance];
    }
}

- (void)setAutoCompleteViewForKeyboardAppearance
{
    [self resetKeyboardAutoCompleteViewFrameForNumberOfRows:MIN(self.autoCompleteSuggestions.count, self.maximumNumberOfAutoCompleteRows)];
    [self.autoCompleteCollectionView setContentInset:UIEdgeInsetsZero];
    [self.autoCompleteCollectionView setScrollIndicatorInsets:UIEdgeInsetsZero];
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

    CGRect newAutoCompleteCollectionViewFrame = [[self class] autoCompleteCollectionViewFrameForTextField:self
        forNumberOfRows:numberOfRows];

    [self.autoCompleteCollectionView setFrame:newAutoCompleteCollectionViewFrame];

    [self.autoCompleteCollectionView setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
    [self.autoCompleteCollectionView scrollRectToVisible:CGRectMake(0, 0, 1, 1) animated:NO];
}

- (void)resetDropDownAutoCompleteViewFrameForNumberOfRows:(NSInteger)numberOfRows
{
    [self.autoCompleteCollectionView.layer setCornerRadius:self.autoCompleteCornerRadius];

    CGRect newAutoCompleteCollectionViewFrame = [[self class] autoCompleteCollectionViewFrameForTextField:self
        forNumberOfRows:numberOfRows];

    [self.autoCompleteCollectionView setFrame:newAutoCompleteCollectionViewFrame];
    [self.autoCompleteCollectionView scrollRectToVisible:CGRectMake(0, 0, 1, 1) animated:NO];
}

- (void)registerAutoCompleteCellNib:(UINib *)nib forCellReuseIdentifier:(NSString *)reuseIdentifier
{
    NSAssert(self.autoCompleteCollectionView, @"Must have an autoCompleteCollectionView to register cells to.");

    if(self.reuseIdentifier){
        [self unregisterAutoCompleteCellForReuseIdentifier:self.reuseIdentifier];
    }

    [self.autoCompleteCollectionView registerNib:nib forCellReuseIdentifier:reuseIdentifier];
    [self setReuseIdentifier:reuseIdentifier];
}


- (void)registerAutoCompleteCellClass:(Class)cellClass forCellReuseIdentifier:(NSString *)reuseIdentifier
{
    NSAssert(self.autoCompleteCollectionView, @"Must have an autoCompleteCollectionView to register cells to.");
    if(self.reuseIdentifier){
        [self unregisterAutoCompleteCellForReuseIdentifier:self.reuseIdentifier];
    }

    BOOL classSettingSupported = [self.autoCompleteCollectionView respondsToSelector:@selector(registerClass:forCellReuseIdentifier:)];
    NSAssert(classSettingSupported, @"Unable to set class for cell for autocomplete table, in iOS 5.0 you can set a custom NIB for a reuse identifier to get similar functionality.");

    [self.autoCompleteCollectionView registerClass:cellClass forCellReuseIdentifier:reuseIdentifier];
    [self setReuseIdentifier:reuseIdentifier];
}

- (void)unregisterAutoCompleteCellForReuseIdentifier:(NSString *)reuseIdentifier
{
    [self.autoCompleteCollectionView registerNib:nil forCellReuseIdentifier:reuseIdentifier];
}

- (void)styleAutoCompleteViewForBorderStyle:(UITextBorderStyle)borderStyle
{
    if([self.autoCompleteDelegate respondsToSelector:
        @selector(autoCompleteTextField:shouldStyleAutoCompleteCollectionView:forBorderStyle:)]){

        if(![self.autoCompleteDelegate autoCompleteTextField:self
            shouldStyleAutoCompleteCollectionView:self.autoCompleteCollectionView forBorderStyle:borderStyle]){
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

    if(self.backgroundColor == [UIColor clearColor]){
        [self setAutoCompleteBackgroundColor:[UIColor whiteColor]];
    } else {
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

    if(self.backgroundColor == [UIColor clearColor]){
        [self setAutoCompleteBackgroundColor:[UIColor whiteColor]];
    } else {
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

    if(self.backgroundColor == [UIColor clearColor]){
        [self setAutoCompleteBackgroundColor:[UIColor whiteColor]];
    } else {
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

#pragma mark - Getters

- (BOOL)autoCompleteViewHidden
{
    return self.autoCompleteCollectionView.hidden;
}

- (void)fetchAutoCompleteSuggestions
{
    if(self.disableAutoCompleteUserInteractionWhileFetching){
        [self.autoCompleteCollectionView setUserInteractionEnabled:NO];
    }

    [self.autoCompleteFetchQueue cancelAllOperations];

    MLPAutoCompleteFetchOperation *fetchOperation = [[MLPAutoCompleteFetchOperation alloc]
        initWithDelegate:self completionsDataSource:self.autoCompleteDataSource autoCompleteTextField:self];

    [self.autoCompleteFetchQueue addOperation:fetchOperation];
}

#pragma mark - Factory Methods

+ (UITableView *)newAutoCompleteCollectionViewForTextField:(MLPAutoCompleteTextField *)textField
{
    CGRect dropDownTableFrame = [[self class] autoCompleteCollectionViewFrameForTextField:textField];

    UITableView *newCollectionView = [[UITableView alloc] initWithFrame:dropDownTableFrame style:UITableViewStylePlain];

    [newCollectionView setDelegate:textField];
    [newCollectionView setDataSource:textField];
    [newCollectionView setScrollEnabled:YES];
    [newCollectionView setSeparatorStyle:UITableViewCellSeparatorStyleNone];

    return newCollectionView;
}

+ (CGRect)autoCompleteCollectionViewFrameForTextField:(MLPAutoCompleteTextField *)textField forNumberOfRows:(NSInteger)numberOfRows
{
    CGRect newCollectionViewFrame = CGRectZero;
    CGFloat height = [[self class] autoCompleteViewHeightForTextField:textField withNumberOfRows:numberOfRows];

    if(textField.autoCompleteAppearsAsKeyboardAccessory){
        CGSize screenSize = [UIScreen mainScreen].bounds.size;
        UIInterfaceOrientation orientation = [[UIApplication sharedApplication] statusBarOrientation];
        newCollectionViewFrame.size.width = UIInterfaceOrientationIsPortrait(orientation) ? screenSize.width : screenSize.height;
        newCollectionViewFrame.size.height = height;
    } else {
        newCollectionViewFrame = [[self class] autoCompleteCollectionViewFrameForTextField:textField];
        newCollectionViewFrame.size.height = height + textField.autoCompleteCollectionView.contentInset.top;
    }

    return newCollectionViewFrame;
}

+ (CGFloat)autoCompleteViewHeightForTextField:(MLPAutoCompleteTextField *)textField withNumberOfRows:(NSInteger)numberOfRows
{
    CGFloat maximumHeightMultiplier = (textField.maximumNumberOfAutoCompleteRows - 0.5);
    CGFloat heightMultiplier;
    if(numberOfRows >= textField.maximumNumberOfAutoCompleteRows){
        heightMultiplier = maximumHeightMultiplier;
    } else {
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

    NSDictionary *boldTextAttributes = @{NSFontAttributeName : boldFont};
    NSDictionary *regularTextAttributes = @{NSFontAttributeName : regularFont};
    NSDictionary *firstAttributes;
    NSDictionary *secondAttributes;

    if(self.reverseAutoCompleteSuggestionsBoldEffect){
        firstAttributes = regularTextAttributes;
        secondAttributes = boldTextAttributes;
    } else {
        firstAttributes = boldTextAttributes;
        secondAttributes = regularTextAttributes;
    }

    NSMutableAttributedString *attributedText = [[NSMutableAttributedString alloc] initWithString:string attributes:firstAttributes];

    substrings = [substrings stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSArray *components = [substrings componentsSeparatedByCharactersInSet:characterSet];

    for (NSString *component in components){
        NSRange range = NSMakeRange(0, string.length);
        while(range.location != NSNotFound){
            range = [string rangeOfString:component options:NSCaseInsensitiveSearch range:range];
            if (range.location != NSNotFound){
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

        if (self.isCancelled){
            return;
        }

        if([self.dataSource respondsToSelector:@selector(autoCompleteTextField:possibleCompletionsForString:completionHandler:)]){

            __block BOOL waitingForSuggestions = YES;
            __weak MLPAutoCompleteFetchOperation *operation = self;

            [self.dataSource autoCompleteTextField:self.textField possibleCompletionsForString:self.incompleteString
                completionHandler:^(NSArray *suggestions){
                [operation performSelector:@selector(didReceiveSuggestions:) withObject:suggestions];
                waitingForSuggestions = NO;
            }];

            while(waitingForSuggestions){
                [NSThread sleepForTimeInterval:250];
                if(self.isCancelled){
                    return;
                }
            }

        } else if ([self.dataSource respondsToSelector:@selector(autoCompleteTextField:possibleCompletionsForString:)]){

            NSArray *results = [self.dataSource autoCompleteTextField:self.textField possibleCompletionsForString:self.incompleteString];

            if(!self.isCancelled){
                [self didReceiveSuggestions:results];
            }

        } else {
            NSAssert(0, @"An autocomplete datasource must implement either autoCompleteTextField:possibleCompletionsForString: or autoCompleteTextField:possibleCompletionsForString:completionHandler:");
        }
    }
}

- (void)didReceiveSuggestions:(NSArray *)suggestions
{
    if(suggestions == nil){
        suggestions = [NSArray array];
    }

    if(!self.isCancelled){

        if(suggestions.count){
            NSObject *firstObject = suggestions[0];
            NSAssert([firstObject isKindOfClass:[NSString class]] ||
                     [firstObject conformsToProtocol:@protocol(MLPAutoCompletionObject)],
                     @"MLPAutoCompleteTextField expects an array with objects that are either strings or conform to the MLPAutoCompletionObject protocol for possible completions.");
        }

        NSDictionary *resultsInfo = @{kFetchedTermsKey: suggestions, kFetchedStringKey : self.incompleteString};

        [(NSObject *)self.delegate performSelectorOnMainThread:@selector(autoCompleteTermsDidFetch:)
            withObject:resultsInfo waitUntilDone:NO];
    };
}

- (id)initWithDelegate:(id<MLPAutoCompleteFetchOperationDelegate>)aDelegate
    completionsDataSource:(id<MLPAutoCompleteTextFieldDataSource>)aDataSource
    autoCompleteTextField:(MLPAutoCompleteTextField *)aTextField
{
    self = [super init];
    if (self) {
        [self setDelegate:aDelegate];
        [self setTextField:aTextField];
        [self setDataSource:aDataSource];
        [self setIncompleteString:aTextField.text];

        if(!self.incompleteString){
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

        if (self.isCancelled){
            return;
        }

        NSArray *results = [self sortedCompletionsForString:self.incompleteString withPossibleStrings:self.possibleCompletions];

        if (self.isCancelled){
            return;
        }

        if(!self.isCancelled){
            [(NSObject *)self.delegate
             performSelectorOnMainThread:@selector(autoCompleteTermsDidSort:)
             withObject:results
             waitUntilDone:NO];
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
    if([inputString isEqualToString:@""]){
        return possibleTerms;
    }

    if(self.isCancelled){
        return [NSArray array];
    }

    NSMutableArray *editDistances = [NSMutableArray arrayWithCapacity:possibleTerms.count];

    for(NSObject *originalObject in possibleTerms) {

        NSString *currentString;
        if([originalObject isKindOfClass:[NSString class]]){
            currentString = (NSString *)originalObject;
        } else if ([originalObject conformsToProtocol:@protocol(MLPAutoCompletionObject)]){
            currentString = [(id <MLPAutoCompletionObject>)originalObject autocompleteString];
        } else {
            NSAssert(0, @"Autocompletion terms must either be strings or objects conforming to the MLPAutoCompleteObject protocol.");
        }

        if(self.isCancelled){
            return [NSArray array];
        }

        NSUInteger maximumRange = (inputString.length < currentString.length) ? inputString.length : currentString.length;

        float editDistanceOfCurrentString = [inputString asciiLevenshteinDistanceWithString:
            [currentString substringWithRange:NSMakeRange(0, maximumRange)]];

        NSDictionary * stringsWithEditDistances = @{
            kSortInputStringKey : currentString ,
            kSortObjectKey : originalObject,
            kSortEditDistancesKey : [NSNumber numberWithFloat:editDistanceOfCurrentString]};

        [editDistances addObject:stringsWithEditDistances];
    }

    if(self.isCancelled){
        return [NSArray array];
    }

    [editDistances sortUsingComparator:^(NSDictionary *string1Dictionary, NSDictionary *string2Dictionary){
        return [string1Dictionary[kSortEditDistancesKey]
                compare:string2Dictionary[kSortEditDistancesKey]];
    }];

    NSMutableArray *prioritySuggestions = [NSMutableArray array];
    NSMutableArray *otherSuggestions = [NSMutableArray array];
    for(NSDictionary *stringsWithEditDistances in editDistances){

        if(self.isCancelled){
            return [NSArray array];
        }

        NSObject *autoCompleteObject = stringsWithEditDistances[kSortObjectKey];
        NSString *suggestedString = stringsWithEditDistances[kSortInputStringKey];

        NSArray *suggestedStringComponents = [suggestedString componentsSeparatedByString:@" "];
        BOOL suggestedStringDeservesPriority = NO;

        for(NSString *component in suggestedStringComponents){
            NSRange occurrenceOfInputString = [[component lowercaseString] rangeOfString:[inputString lowercaseString]];

            if (occurrenceOfInputString.length != 0 && occurrenceOfInputString.location == 0) {
                suggestedStringDeservesPriority = YES;
                [prioritySuggestions addObject:autoCompleteObject];
                break;
            }

            if([inputString length] <= 1){
                //if the input string is very short, don't check anymore components of the input string.
                break;
            }
        }

        if(!suggestedStringDeservesPriority){
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

