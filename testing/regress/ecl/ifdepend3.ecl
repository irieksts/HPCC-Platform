/*##############################################################################

    HPCC SYSTEMS software Copyright (C) 2012 HPCC Systems.

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
############################################################################## */

namesRecord := 
            RECORD
string20        surname;
string10        forename;
integer2        age := 25;
            END;

namesTable := dataset([
        {'Halliday','Gavin',31},
        {'Halliday','Liz',30},
        {'Zingo','Abi',10},
        {'X','Z'}], namesRecord);


s := sort(distribute(namesTable, hash(surname) % 1), forename, surname, age, local);

makeSplit1 := dedup(sort(s, surname, forename, age), age, local);

boolean isOk := true : stored('isOkay');

x1 := if(isOk, s, makeSplit1);

output(x1);

output(s);
output(sort(makeSplit1, age, surname, forename));

