# Simple image server in Zig
Note: This was made for my personal use, so extra features will only be added if requested (or contributed).

## API
Access control is done through the Authorization header with the token in the config file.

`POST /stop` (requires the token): Stops the server.  
`POST /upload` (requires the token): Uploads an image, specified as the `file` field in a `multipart/form-data` body. Responds with the embeddable image link.  
`GET /:hash`: Requests the embeddable image corresponding to the `hash` parameter.  
`GET /:hash/direct`: Requests the raw image corresponding to the `hash` parameter.  
`DELETE /:hash` (requires the token): Deletes the image corresponding to the `hash` parameter.