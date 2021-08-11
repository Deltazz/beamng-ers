$zip_path=$args[0]
Write-Host "Unzipping $zip_path into temp"
Expand-Archive $zip_path temp
$car_name = (Get-ChildItem -Path temp\vehicles -Name)
$car_jbeam_file_name = (Get-ChildItem -Path ./temp/vehicles/$car_name/ -Filter "*.dae" -Name)
$car_jbeam_file_name = $car_jbeam_file_name -replace '(\w+)\.dae','$1.jbeam'
$car_jbeam_path = "temp\vehicles\$car_name\$car_jbeam_file_name"

Write-Host "Adding MGU-K slot to main jbeam file"
# Add MGU-K slot to main jbeam file
(Get-Content $car_jbeam_path) | 
    Foreach-Object {
        $_ # send the current line to output
        if ($_ -match '\["type", "default", "description"\]') 
        {
            #Add Lines after the selected pattern 
            '		["MGU_K", "MGU_K", "MGU-K"]'
        }
    } | Set-Content $car_jbeam_path

Write-Host "Adding MGU-K related files"
# Add MGU-K
Copy-Item "mod_files\ui" -Destination "temp\" -Recurse
Copy-Item "mod_files\vehicles\_vehicle_name_\lua" -Destination "temp\vehicles\$car_name\" -Recurse
Copy-Item "mod_files\vehicles\_vehicle_name_\input_actions.json" -Destination "temp\vehicles\$car_name\"
Copy-Item "mod_files\vehicles\_vehicle_name_\mgu_k.jbeam" -Destination "temp\vehicles\$car_name\"

Write-Host "Creating a new BeamNG.drive mod (${car_name}_hybrid.zip)"
# Create new beam zip
Compress-Archive -Path temp\* -DestinationPath "${car_name}_hybrid.zip"

Write-Host "Removing temp folder"
# Remove temp folder
Remove-Item temp -Recurse

Write-Host "Done"