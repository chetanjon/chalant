# Chalant 1.15.2

Cleanup is faster, and it keeps your words.

## Faster, all day

Cleaning a sentence now takes about half a second where it used to take
two or more, and it stays that fast however long Chalant has been running.
Before, the cleanup got a little slower with every sentence you dictated
and, after a long enough day, quietly stopped working until you relaunched.
Fixed.

## Your words, tidied, not rewritten

Cleanup now makes the smallest changes it can: fillers, false starts and
stutters go, punctuation and obvious slips get fixed, and everything else
stays as you said it. "What next?" stays "What next?". Contractions stay
contractions. Measured on ninety-two of the founder's own dictations, the
number of sentences where cleanup put in words that were never said fell
from twenty-three to one or two.

## Small things you would have noticed eventually

Curly quotes the model liked to introduce come back as plain ones, so a
dictated command pastes cleanly into a terminal. A final period or question
mark the model dropped is put back. A word the model accidentally doubled
is caught before it lands.
