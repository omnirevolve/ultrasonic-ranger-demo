#include <stdio.h>
#include <stdlib.h>

int main(void){
  FILE* f = fopen("/sys/kernel/debug/ranger_k/distances", "r");
  if (!f){ perror("open distances"); return 1; }
  char buf[256] = {0};
  if (fgets(buf, sizeof(buf), f)){
    printf("distances: %s", buf);
  }
  fclose(f);
  f = fopen("/sys/kernel/debug/ranger_k/stats", "r");
  if (f && fgets(buf, sizeof(buf), f)){
    printf("stats: %s", buf);
    fclose(f);
  }
  return 0;
}
