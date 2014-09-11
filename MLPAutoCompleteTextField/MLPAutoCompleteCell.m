//
//  MLPAutoCompleteCell.m
//
//  Created by Christoph Zelazowski on 1/11/14.
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

#import "MLPAutoCompleteCell.h"

static const CGFloat kDefaultHorizontalPadding = 10.0;

@implementation MLPAutoCompleteCell

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _textLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _textLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _textLabel.font = [UIFont systemFontOfSize:14];
        _textLabel.textColor = [UIColor darkTextColor];
        [self.contentView addSubview:_textLabel];
    }
    return self;
}

- (void)prepareForReuse
{
    self.textLabel.text = nil;
}

- (void)layoutSubviews
{
    [super layoutSubviews];

    CGRect frame = self.contentView.frame;
    _textLabel.frame = CGRectMake(kDefaultHorizontalPadding, 0, frame.size.width - kDefaultHorizontalPadding, frame.size.height);
}

- (CGSize)sizeThatFits:(CGSize)size
{
    CGSize labelSize = [_textLabel sizeThatFits:size];
    return CGSizeMake(MIN(labelSize.width + kDefaultHorizontalPadding, size.width), size.height);
}

@end
