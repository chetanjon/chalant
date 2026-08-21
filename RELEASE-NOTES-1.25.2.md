# Chalant 1.25.2

The clipboard keeps one of each.

## A copy-back is a restore, not a copy

Pressing Copy on a row in the Clipboard tab puts that content back on your
clipboard, ready to paste. Chalant no longer records its own write as a new
copy, so the history stays exactly as it was. Screenshots felt this worst:
every copy-back used to add the same picture again as a brand-new entry.
Now the list only grows when you actually copy something.
