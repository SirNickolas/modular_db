#!/bin/sed -f

/<!--\s*EXAMPLE\s*-->/,$ !b
0,/^/ {
    a ```d
    r examples/basic/src/main.d
    b
}
/<!--\s*END\s*-->/,$ !d
0,/^/ i ```
