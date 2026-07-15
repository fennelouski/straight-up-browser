#!/bin/bash

# Dev-loop build of the CLI tool. The app's Xcode build compiles and signs
# this same source into Internet.app/Contents/Helpers/browser-cli.
echo "Building Straight Up Browser CLI..."

swiftc -O browser-cli/main.swift -o browser-cli-tool

if [ $? -eq 0 ]; then
    echo "CLI tool built successfully: ./browser-cli-tool"
    chmod +x ./browser-cli-tool
    echo "Made executable"
else
    echo "Build failed"
    exit 1
fi
