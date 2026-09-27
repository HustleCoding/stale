// Moving things to the user's Trash, and deleting what is already in it.
#pragma once

#include <string>

namespace stale {

// Folder whose entries are the items in the user's Trash (~/.Trash on macOS, the freedesktop
// home trash's files/ on Linux).
std::string trashFilesDir(const std::string& home);

// Moves path to the Trash (Finder's on macOS, the freedesktop trash on Linux, so file
// managers can put it back). On failure returns false and sets *error.
bool moveToTrash(const std::string& path, std::string* error);

// Permanently deletes an item that is in the Trash, with its restore metadata.
bool deleteFromTrash(const std::string& path, std::string* error);

}  // namespace stale
