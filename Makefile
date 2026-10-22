NAME = auto-scrollmode-changer
LABEL = com.fernandorobles.$(NAME)
BIN_DIR = $(HOME)/.local/bin
BIN = $(BIN_DIR)/$(NAME)
PLIST = $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG = $(HOME)/Library/Logs/$(NAME).log
VENDOR ?= 2821
PRODUCT ?= 6304
APP = Auto Scroll Mode.app

build:
	swiftc -O -o $(NAME) main.swift

install: build
	mkdir -p $(BIN_DIR) $(HOME)/Library/LaunchAgents
	cp $(NAME) $(BIN)
	sed -e 's|@LABEL@|$(LABEL)|' -e 's|@BIN@|$(BIN)|' -e 's|@LOG@|$(LOG)|' \
		-e 's|@VENDOR@|$(VENDOR)|' -e 's|@PRODUCT@|$(PRODUCT)|' launchagent.plist.in > $(PLIST)
	-launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(PLIST)

uninstall:
	-launchctl bootout gui/$$(id -u)/$(LABEL)
	rm -f $(PLIST) $(BIN)

app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	swiftc -O -parse-as-library -o "$(APP)/Contents/MacOS/AutoScrollMode" gui.swift
	cp Info.plist "$(APP)/Contents/Info.plist"
	cp $(NAME) "$(APP)/Contents/Resources/$(NAME)"
	codesign --force --deep --sign - "$(APP)"

logs:
	tail -f $(LOG)

.PHONY: build install uninstall app logs
