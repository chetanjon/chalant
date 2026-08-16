# Chalant 1.14.2

Long paragraphs are tidied properly now.

## A few sentences at a time

The tidying in 1.14.0 and 1.14.1 read a whole paragraph in one go and asked
the model to rewrite it. On short things that was fine. On a long ramble it
was a coin flip: sometimes a "not" went missing, sometimes it invented half
a sentence, and once in a while it rewrote a story you told about yourself
as if it were about someone else. The guard behind it caught most of that
and handed you your raw words instead, which is why long dictation often
came out untidied.

Chalant now splits a long dictation at the ends of sentences and tidies it
a few sentences at a time. The model on your Mac is small, and that is the
size of piece it can be trusted with. Measured on a real long paragraph, it
went from three good results in five to five in five, with the same wait.

## One bad sentence no longer spoils the rest

If the guard rejects one piece, only that piece comes through as you said
it. The rest of the paragraph is still tidied. Before, one rejected phrase
anywhere threw the whole cleanup away.

## What is still not perfect

When you report what someone else said, the tidying can still get a "me"
and a "you" the wrong way round in that one sentence. It no longer rewrites
you as "he" all the way through. That is the size of what is left.
