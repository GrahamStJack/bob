#include "base/extra.h"
#include "base/one.h"
#include "base/macros.h"

#include <iostream>


int main(int argc, char *argv[])
{
  double x = 5.0;
  SAY("The square of " << x << " is " << square(x));
  return 0;
}
