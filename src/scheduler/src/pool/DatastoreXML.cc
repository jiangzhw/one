/* -------------------------------------------------------------------------- */
/* Copyright 2002-2013, OpenNebula Project (OpenNebula.org), C12G Labs        */
/*                                                                            */
/* Licensed under the Apache License, Version 2.0 (the "License"); you may    */
/* not use this file except in compliance with the License. You may obtain    */
/* a copy of the License at                                                   */
/*                                                                            */
/* http://www.apache.org/licenses/LICENSE-2.0                                 */
/*                                                                            */
/* Unless required by applicable law or agreed to in writing, software        */
/* distributed under the License is distributed on an "AS IS" BASIS,          */
/* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   */
/* See the License for the specific language governing permissions and        */
/* limitations under the License.                                             */
/* -------------------------------------------------------------------------- */

#include <sstream>

#include "DatastoreXML.h"

/* -------------------------------------------------------------------------- */
/* -------------------------------------------------------------------------- */

int DatastoreXML::ds_num_paths = 2;

const char * DatastoreXML::ds_paths[] = {
    "/DATASTORE/TEMPLATE/",
    "/DATASTORE/"
};

/* -------------------------------------------------------------------------- */
/* -------------------------------------------------------------------------- */

void DatastoreXML::init_attributes()
{
    oid        = atoi(((*this)["/DATASTORE/ID"] )[0].c_str() );
    cluster_id = atoi(((*this)["/DATASTORE/CLUSTER_ID"] )[0].c_str() );

    free_mb = static_cast<unsigned int>(
        atol(((*this)["/DATASTORE/FREE_MB"])[0].c_str()));

    ObjectXML::paths     = ds_paths;
    ObjectXML::num_paths = ds_num_paths;
}

/* -------------------------------------------------------------------------- */
/* -------------------------------------------------------------------------- */
