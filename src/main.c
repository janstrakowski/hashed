#include <stdio.h>

int main(int argc, char *argv[]) {
  printf("Hello, World!\n");

  printf("CLI arguments: ");
  int first = 1;
  for (int i = 1; i < argc; i++) {
    if (!first) printf(" ");
    printf("%s", argv[i]);
  }
  if (argc == 1) {
    printf("*None*");
  }
  printf("\n");
}
