# hyperlist-display: pure x86_64 assembly, no libc.
#   nasm -f elf64 + ld, nothing else. The deployed hook is a symlink to
#   the binary this produces, so `make` is also `install`.
all: hyperlist-display

hyperlist-display: hyperlist-display.asm
	nasm -f elf64 $< -o hyperlist-display.o
	ld hyperlist-display.o -o $@

clean:
	rm -f hyperlist-display.o hyperlist-display

.PHONY: all clean
