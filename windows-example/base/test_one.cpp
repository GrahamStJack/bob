#include "base/one.h"
#include "base/macros.h"

#include <iostream>
#include <cassert>

int main(int argc, char *argv[])
{
    double x = 5.0;
    double xx = square(x);

    ASSERT(xx = x * x, "Unexpected result");
    return 0;
}
