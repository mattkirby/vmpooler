### API

vmpooler provides a REST API for VM management.  The following examples use `curl` for communication.

#### Token operations

Token-based authentication can be used when requesting or modifying VMs.  The `/token` route can be used to create, query, or delete tokens.  See the provided YAML configuration example, [vmpooler.yaml.example](vmpooler.yaml.example), for information on configuring an authentication store to use when performing token operations.

##### GET /token

Get a list of issued tokens.

```
$ curl -u jdoe --url vmpooler.company.com/api/v1/token
Enter host password for user 'jdoe':
```
```json
{
    "ok": true,
    "utpg2i2xswor6h8ttjhu3d47z53yy47y": {
      "created": "2015-04-28 19:17:47 -0700"
    }
}
```

##### POST /token

Generate a new authentication token.

```
$ curl -X POST -u jdoe --url vmpooler.company.com/api/v1/token
Enter host password for user 'jdoe':
```
```json
{
    "ok": true,
    "token": "utpg2i2xswor6h8ttjhu3d47z53yy47y"
}
```

##### GET /token/&lt;token&gt;

Get information about an existing token (including associated VMs).

```
$ curl --url vmpooler.company.com/api/v1/token/utpg2i2xswor6h8ttjhu3d47z53yy47y
```
```json
{
  "ok": true,
  "utpg2i2xswor6h8ttjhu3d47z53yy47y": {
    "user": "jdoe",
    "created": "2015-04-28 19:17:47 -0700",
    "last": "2015-11-04 12:28:37 -0700",
    "vms": {
      "running": [
        "dqs4914g2wjyy5w",
        "hul7ib0ssr0f4o0"
      ]
    }
  }
}
```

##### DELETE /token/&lt;token&gt;

Delete an authentication token.

```
$ curl -X DELETE -u jdoe --url vmpooler.company.com/api/v1/token/utpg2i2xswor6h8ttjhu3d47z53yy47y
Enter host password for user 'jdoe':
```
```json
{
  "ok": true
}
```

#### VM operations

##### GET /vm

Retrieve a list of available VM pools.

```
$ curl --url vmpooler.company.com/api/v1/vm
```
```json
[
  "debian-7-i386",
  "debian-7-x86_64"
]
```

##### POST /vm

Useful for batch operations; post JSON (see format below), get back VMs.

If an authentication store is configured, an authentication token supplied via the `X-AUTH-TOKEN` HTTP header will modify a VM's default lifetime.  See the provided YAML configuration example, [vmpooler.yaml.example](vmpooler.yaml.example), and the 'token operations' section above for more information.

```
$ curl -d '{"debian-7-i386":"2","debian-7-x86_64":"1"}' --url vmpooler.company.com/api/v1/vm
```
```json
{
  "ok": true,
  "debian-7-i386": {
    "hostname": [
      "o41xtodlvnvu5cw",
      "khirruvwfjlmx3y"
    ]
  },
  "debian-7-x86_64": {
    "hostname": "y91qbrpbfj6d13q"
  },
  "domain": "company.com"
}
```

**NOTE: Returns either all requested VMs or no VMs.**

##### POST /vm/&lt;pool&gt;

Check-out a VM or VMs.

```
$ curl -d --url vmpooler.company.com/api/v1/vm/debian-7-i386
```
```json
{
  "ok": true,
  "debian-7-i386": {
    "hostname": "fq6qlpjlsskycq6"
  },
  "domain": "company.com"
}
```

Multiple VMs can be requested by using multiple query parameters in the URL:

```
$ curl -d --url vmpooler.company.com/api/v1/vm/debian-7-i386+debian-7-i386+debian-7-x86_64
```

```json
{
  "ok": true,
  "debian-7-i386": {
    "hostname": [
      "sc0o4xqtodlul5w",
      "4m4dkhqiufnjmxy"
    ]
  },
  "debian-7-x86_64": {
    "hostname": "zb91y9qbrbf6d3q"
  },
  "domain": "company.com"
}
```

**NOTE: Returns either all requested VMs or no VMs.**

##### GET /vm/&lt;hostname&gt;

Query a checked-out VM.

```
$ curl --url vmpooler.company.com/api/v1/vm/pxpmtoonx7fiqg6
```
```json
{
  "ok": true,
  "pxpmtoonx7fiqg6": {
    "template": "centos-6-x86_64",
    "lifetime": 12,
    "running": 3.1,
    "state": "running",
    "tags": {
      "department": "engineering",
      "user": "jdoe"
    },
    "domain": "company.com"
  }
}
```

##### PUT /vm/&lt;hostname&gt;

Modify a checked-out VM.

The following are valid PUT parameters and their required data structures:

parameter | description | required structure
--------- | ----------- | ------------------
*lifetime* | VM TTL (in hours) | integer
*tags* | free-form VM tagging | hash

Any modifications can be verified using the [GET /vm/&lt;hostname&gt;](#get-vmhostname) endpoint.

If an authentication store is configured, an authentication token is required (via the `X-AUTH-TOKEN` HTTP header) to access this route.  See the provided YAML configuration example, [vmpooler.yaml.example](vmpooler.yaml.example), and the 'token operations' section above for more information.

```
$ curl -X PUT -d '{"lifetime":"2"}' --url vmpooler.company.com/api/v1/vm/fq6qlpjlsskycq6
```
```json
{
  "ok": true
}
```

```
$ curl -X PUT -d '{"tags":{"department":"engineering","user":"jdoe"}}' --url vmpooler.company.com/api/v1/vm/fq6qlpjlsskycq6
```
```json
{
  "ok": true
}
```

##### DELETE /vm/&lt;hostname&gt;

Schedule a checked-out VM for deletion.

```
$ curl -X DELETE --url vmpooler.company.com/api/v1/vm/fq6qlpjlsskycq6
```
```json
{
  "ok": true
}
```

#### Adding additional disk(s)

##### POST /vm/&lt;hostname&gt;/disk/&lt;size&gt;

Add an additional disk to a running VM.

````
$ curl -X POST -H X-AUTH-TOKEN:a9znth9dn01t416hrguu56ze37t790bl --url vmpooler.company.com/api/v1/vm/fq6qlpjlsskycq6/disk/8
````
````json
{
  "ok": true,
  "fq6qlpjlsskycq6": {
    "disk": "+8gb"
  }
}
````

Provisioning and attaching disks can take a moment, but once the task completes it will be reflected in a `GET /vm/<hostname>` query:

````
$ curl --url vmpooler.company.com/api/v1/vm/fq6qlpjlsskycq6
````
````json
{
  "ok": true,
  "fq6qlpjlsskycq6": {
    "template": "debian-7-x86_64",
    "lifetime": 2,
    "running": 0.08,
    "state": "running",
    "disk": [
      "+8gb"
    ],
    "domain": "delivery.puppetlabs.net"
  }
}

````

#### VM snapshots

##### POST /vm/&lt;hostname&gt;/snapshot

Create a snapshot of a running VM.

````
$ curl -X POST -H X-AUTH-TOKEN:a9znth9dn01t416hrguu56ze37t790bl --url vmpooler.company.com/api/v1/vm/fq6qlpjlsskycq6/snapshot
````
````json
{
  "ok": true,
  "fq6qlpjlsskycq6": {
    "snapshot": "n4eb4kdtp7rwv4x158366vd9jhac8btq"
  }
}
````

Snapshotting a live VM can take a moment, but once the snapshot task completes it will be reflected in a `GET /vm/<hostname>` query:

````
$ curl --url vmpooler.company.com/api/v1/vm/fq6qlpjlsskycq6
````
````json
{
  "ok": true,
  "fq6qlpjlsskycq6": {
    "template": "debian-7-x86_64",
    "lifetime": 2,
    "running": 0.08,
    "state": "running",
    "snapshots": [
      "n4eb4kdtp7rwv4x158366vd9jhac8btq"
    ],
    "domain": "delivery.puppetlabs.net"
  }
}
````

##### POST /vm/&lt;hostname&gt;/snapshot/&lt;snapshot&gt;

Revert a VM back to a snapshot.

````
$ curl X POST -H X-AUTH-TOKEN:a9znth9dn01t416hrguu56ze37t790bl --url vmpooler.company.com/api/v1/vm/fq6qlpjlsskycq6/snapshot/n4eb4kdtp7rwv4x158366vd9jhac8btq
````
````json
{
  "ok": true
}
````

#### Status and metrics

##### GET /status

A "live" status endpoint, representing the current state of the service.

```
$ curl --url vmpooler.company.com/api/v1/status
```
```json
{
  "capacity": {
    "current": 716,
    "total": 717,
    "percent": 99.9
  },
  "clone": {
    "duration": {
      "average": 8.8,
      "min": 2.79,
      "max": 69.76
    },
    "count": {
      "total": 1779
    }
  },
  "queue": {
    "pending": 1,
    "cloning": 0,
    "booting": 1,
    "ready": 716,
    "running": 142,
    "completed": 0,
    "total": 859
  },
  "status": {
    "ok": true,
    "message": "Battle station fully armed and operational."
  }
}
```

If there are empty pools, the "status" section will convey this:

```json
  "status": {
    "ok": false,
    "message": "Found 2 empty pools.",
    "empty": [
      "centos-6-x86_64",
      "debian-7-x86_64"
    ]
  }
```

##### GET /summary[?from=YYYY-MM-DD[&to=YYYY-MM-DD]]

Returns a summary, or report, for the timespan between `from` and `to` (inclusive)
parameters. The response includes both an overall and daily view of tracked
metrics, such as boot and cloning durations.

Any omitted query parameter will default to now/today. A request without any
parameters will result in the current day's summary.

```
$ curl --url vmpooler.company.com/api/v1/summary
```
```json
{
  "boot": {
    "duration": {
      "average": 106.6,
      "min": 83.09,
      "max": 121.06,
      "total": 639.36,
    },
    "count": {
      "average": 6,
      "min": 6,
      "max": 6,
      "total": 6,
    }
  },
  "clone": {
    "duration": {
      "average": 4.6,
      "min": 2.78,
      "max": 8.1,
      "total": 63.94,
    },
    "count": {
      "average": 14,
      "min": 14,
      "max": 14,
      "total": 14,
    }
  },
  "tag": {
    "department": {
      "engineering": 14,
      "help desk": 10,
      "IT": 44,
      "total": 68
    },
    "user": {
      "arodgers": 54,
      "cmatthews": 10,
      "jnelson": 4,
      "total": 68
    }
  },
  "daily": [
    {
      "date": "2015-03-11",
      "boot": {
        "duration": {
          "average": 106.6,
          "min": 83.09,
          "max": 121.06,
          "total": 639.36
        },
        "count": {
          "total": 6
        }
      },
      "clone": {
        "duration": {
          "average": 4.6,
          "min": 2.78,
          "max": 8.1,
          "total": 63.94
        },
        "count": {
          "total": 14
        }
      },
      "tag": {
        "department": {
          "engineering": 14,
          "help desk": 10,
          "IT": 44,
          "total": 68
        },
        "user": {
          "arodgers": 54,
          "cmatthews": 10,
          "jnelson": 4,
          "total": 68
        }
      }
    }
  ]
}
```

```
$ curl -G -d 'from=2015-03-10' -d 'to=2015-03-11' --url vmpooler.company.com/api/v1/summary
```
```json
{
  "boot": {...},
  "clone": {...},
  "daily": [
    {
      "date": "2015-03-10",
      "boot": {
        "duration": {
          "average": 0,
          "min": 0,
          "max": 0,
          "total": 0
        },
        "count": {
          "total": 0
        }
      },
      "clone": {
        "duration": {
          "average": 0,
          "min": 0,
          "max": 0,
          "total": 0
        },
        "count": {
          "total": 0
        }
      },
      "tag": { }
    },
    {
      "date": "2015-03-11",
      "boot": {
        "duration": {
          "average": 106.6,
          "min": 83.09,
          "max": 121.06,
          "total": 639.36
        },
        "count": {
          "total": 6
        }
      },
      "clone": {
        "duration": {
          "average": 4.6,
          "min": 2.78,
          "max": 8.1,
          "total": 63.94
        },
        "count": {
          "total": 14
        }
      },
      "tag": { }
    }
  ]
}
```

#### Changing configuration via API

##### POST /config/poolsize

Change pool size without having to restart the service.

All pool template changes requested must be for pools that exist in the vmpooler configuration running, or a 404 code will be returned

When a pool size is changed due to the configuration posted a 201 status will be returned. When the pool configuration is valid, but will not result in any changes, 200 is returned.

Pool size configuration changes persist through application restarts, and take precedence over a pool size value configured in the pool configuration provided when the application starts. This persistence is dependent on redis. So, if the redis data is lost then the configuration updates revert to those provided at startup at the next application start.

An authentication token is required in order to change pool configuration when authentication is configured.
Responses:
* 200 - No changes required
* 201 - Changes made on at least one pool with changes requested
* 404 - An error was encountered while evaluating requested changes
```
$ curl -d '{"debian-7-i386":"2","debian-7-x86_64":"1"}' --url vmpooler.company.com/api/v1/config/poolsize
```
```json
{
  "ok": true
}
```

##### POST /config/pooltemplate

Change the template configured for a pool, and replenish the pool with instances built from the new template.

All pool template changes requested must be for pools that exist in the vmpooler configuration running, or a 404 code will be returned

When a pool template is changed due to the configuration posted a 201 status will be returned. When the pool configuration is valid, but will not result in any changes, 200 is returned.

A pool template being updated will cause the following actions, which are logged in vmpooler.log:
* Destroy all instances for the pool template being updated that are in the ready and pending state
* Halt repopulating the pool while creating template deltas for the newly configured template
* Unblock pool population and let the pool replenish with instances based on the newly configured template

Pool template changes persist through application restarts, and take precedence over a pool template configured in the pool configuration provided when the application starts. This persistence is dependent on redis. As a result, if the redis data is lost then the configuration values revert to those provided at startup at the next application start.

An authentication token is required in order to change pool configuration when authentication is configured.

Responses:
* 200 - No changes required
* 201 - Changes made on at least one pool with changes requested
* 404 - An error was encountered while evaluating requested changes
```
$ curl -d '{"debian-7-i386":"templates/debian-7-i386"}' --url vmpooler.company.com/api/v1/config/pooltemplate
```
```json
{
  "ok": true
}
```
