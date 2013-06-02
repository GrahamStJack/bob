#include "base/two.h"
#include "base/macros.h"

#include <iostream>

int main(int argc, char *argv[])
{
    double x = 5.0;
    double xxx = cube(x);

    ASSERT(xxx = x * x * x, "Unexpected result");
    return 0;
}
