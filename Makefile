LUA     = luajit
CFLAGS += $(shell pkg-config --cflags $(LUA))

TARGET  = lua/nrepl/debug/debugger.so

all: $(TARGET)

$(TARGET): src/debugger.c
	$(CC) $(CFLAGS) -fPIC -shared -o $@ $< $(LDFLAGS)

clean:
	rm -f $(TARGET)

.PHONY: all test clean
