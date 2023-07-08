#include <stddef.h>

struct Payload {
    const char *exec;
    const size_t argc_pre;
    const char **argv_pre;
};

const char exec[];
const char *argv_pre[];

struct Payload payload __attribute__((__section__(".payload"), used, retain)) = {
    .exec = exec,
    .argc_pre = 1,
    .argv_pre = argv_pre,
};

const char exec[] __attribute__((__section__(".payload_rodata"), used, retain)) = "/bin/echo";
const char hello[];
const char *argv_pre[] __attribute__((__section__(".payload"), used, retain)) = {hello};
const char hello[] __attribute__((__section__(".payload_rodata"), used, retain)) = "Hello";
