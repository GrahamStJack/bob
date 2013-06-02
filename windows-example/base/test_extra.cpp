#include "base/extra.h"
#include "base/macros.h"

#include <iostream>

int main(int argc, char *argv[])
{
    double x = 5.0;
    double xxxx = quad(x);

    ASSERT(xxxx = x * x * x * x, "Unexpected result");
    return 0;
}
