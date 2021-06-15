#include <unistd.h>
#include <stdlib.h>

int main(int argc, char * argv[]) {
  return lseek(atoi(argv[1]), 0L, SEEK_SET);
}
