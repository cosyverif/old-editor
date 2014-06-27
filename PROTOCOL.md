Protocol of the Edition Server
==============================

1. Open the connexion
2. Send your __token__
3. Send your commands and receive the answer
4. Close the connexion

All commands and their answers are in JSON format. A command has the
following shape:

    {
      "action": "...", // required action
      ... // parameters
    }

An answer has the following shape:

    {
      "accepted": true or false,
      "reason": "..." // only when rejected
      ... // results when accepted
    }

Command "set-token"
-------------------

This command is only usable by the administrator. It adds a token
associated with read and write permissions. If the token already exists,
it is overwritten.

For instance:

    {
      "action": "set-token",
      "token" : "...", // the token
      "can-read" : true or false,
      "can-write": true or false
    }

The answer is:

    {
      "accepted": true or false,
      "reason": "..." // only when rejected
    }

Command "get-model"
-------------------

For instance:

    {
      "action": "get-model"
    }

When accepted, the answer is:

    {
      "accepted": true,
      "data": "..." // some lua code
    }

Command "list-patches"
----------------------

    {
      "action": "list-patches",
      "from": "...", // optional start
      "to": "..." // optional end
    }

    {
      "accepted": true,
      "patches":
        [
          { "id": "..." }, // patch identifier
          ...
        ]
    }

Command "get-patches"
---------------------

    {
      "action": "list-patches",
      "id": "...", // optional patch identifier
    }

    {
      "action": "list-patches",
      "from": "...", // optional start
      "to": "..." // optional end
    }

    {
      "accepted": true,
      "patches":
        [
          {
            "id":   "...", // patch identifier
            "data": "..."  // some lua code
          },
          ...
        ]
    }

Command "add-patch"
-------------------

    {
      "action": "add-patch",
      "origin": "...", // identifier for client
      "data":   "..."  // some lua code
    }

    {
      "accepted": true,
      "patches":
        [
          {
            "id":   "...", // patch identifier
            "data": "..."  // some lua code
          },
          ...
        ]
    }

Command "update"
----------------

    {
      "action": "update",
      "patches":
        [
          {
            "id":   "...", // patch identifier
            "data": "..."  // some lua code
          },
          ...
        ]
    }

