#ifndef BASE_MACROS_H
#define BASE_MACROS_H

#include <iostream>
#include <cstdlib>

#define SAY(stuff)              \
  do                            \
  {                             \
    std::cerr << stuff << "\n"; \
  }                             \
  while (0)

#define ASSERT(expr, stuff)       \
  do                              \
  {                               \
    if (!(expr))                  \
    {                             \
      std::cerr << stuff << "\n"; \
      abort();                    \
    }                             \
  }                               \
  while (0)

#endif /* BASE_MACROS_H */
