# standalone build of the C core (module sslcore); needs only cc and the Sprint headers (SPRINT_INC)
SPRINT_INC ?= ../src
CFLAGS ?= -O2 -std=c11 -Wall -Wextra
all: libsslcore.a
libsslcore.a: $(patsubst %.c,%.o,$(wildcard c/*.c))
	ar rcs $@ $^
%.o: %.c
	$(CC) $(CFLAGS) -I$(SPRINT_INC) -c -o $@ $<
clean:
	rm -f c/*.o libsslcore.a
